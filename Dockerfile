# Copied from below and modified it
# https://github.com/hexpm/bob/blob/master/priv/scripts/docker/elixir-alpine.dockerfile
FROM alpine:3.12.7 AS build-elixir

RUN apk add --no-cache --update \
  wget \
  unzip \
  make

RUN wget -q -O elixir.zip "https://repo.hex.pm/builds/elixir/v1.12-otp-24.zip" && unzip -d /ELIXIR elixir.zip
WORKDIR /ELIXIR
RUN make -o compile DESTDIR=/ELIXIR_LOCAL install

FROM alpine:3.12.7 AS final-elixir
COPY --from=build-elixir /ELIXIR_LOCAL/usr/local /usr/local

# Copied from below and modified it
# https://github.com/hexpm/bob/blob/master/priv/scripts/docker/erlang-alpine.dockerfile
FROM alpine:3.12.7 AS build-erlang

RUN apk --no-cache upgrade
RUN apk add --no-cache \
  dpkg-dev \
  dpkg \
  bash \
  pcre \
  ca-certificates \
  libressl-dev \
  ncurses-dev \
  unixodbc-dev \
  zlib-dev \
  lksctp-tools-dev \
  autoconf \
  build-base \
  perl-dev \
  wget \
  tar \
  binutils

RUN mkdir -p /OTP/subdir
RUN wget -nv "https://github.com/erlang/otp/archive/OTP-24.0.tar.gz" && tar -zxf "OTP-24.0.tar.gz" -C /OTP/subdir --strip-components=1
WORKDIR /OTP/subdir
RUN ./otp_build autoconf

ARG PIE_CFLAGS
ARG CF_PROTECTION
ARG CFLAGS="-g -O2 -fstack-clash-protection ${CF_PROTECTION} ${PIE_CFLAGS}"

RUN ./configure \
  --build="$(dpkg-architecture --query DEB_HOST_GNU_TYPE)" \
  --without-javac \
  --without-wx \
  --without-debugger \
  --without-observer \
  --without-jinterface \
  --without-cosEvent\
  --without-cosEventDomain \
  --without-cosFileTransfer \
  --without-cosNotification \
  --without-cosProperty \
  --without-cosTime \
  --without-cosTransactions \
  --without-et \
  --without-gs \
  --without-ic \
  --without-megaco \
  --without-orber \
  --without-percept \
  --without-typer \
  --with-ssl \
  --enable-threads \
  --enable-dirty-schedulers \
  --disable-hipe
RUN make -j$(getconf _NPROCESSORS_ONLN)
RUN make install
RUN make docs DOC_TARGETS=chunks
RUN make install-docs DOC_TARGETS=chunks
RUN find /usr/local -regex '/usr/local/lib/erlang/\(lib/\|erts-\).*/\(man\|obj\|c_src\|emacs\|info\|examples\)' | xargs rm -rf
RUN find /usr/local -name src | xargs -r find | grep -v '\.hrl$' | xargs rm -v || true
RUN find /usr/local -name src | xargs -r find | xargs rmdir -vp || true
RUN scanelf --nobanner -E ET_EXEC -BF '%F' --recursive /usr/local | xargs -r strip --strip-all
RUN scanelf --nobanner -E ET_DYN -BF '%F' --recursive /usr/local | xargs -r strip --strip-unneeded

FROM alpine:3.12.7 AS final-erlang

RUN apk add --update --no-cache \
  libstdc++ \
  ncurses \
  libressl \
  unixodbc \
  lksctp-tools

COPY --from=build-erlang /usr/local /usr/local

# Stage 1
# Builds the Livebook release
FROM alpine:3.12.7 AS build-livebook

COPY --from=final-elixir /usr/local /usr/local
COPY --from=final-erlang /usr/local /usr/local

RUN apk add --no-cache build-base git ncurses-libs libressl

WORKDIR /app

# Install hex and rebar
RUN mix local.hex --force && \
    mix local.rebar --force

# Build for production
ENV MIX_ENV=prod

# Install mix dependencies
RUN git clone https://github.com/livebook-dev/livebook.git
RUN cp -R livebook/* .
# COPY mix.exs mix.lock ./
# COPY config config
RUN mix do deps.get, deps.compile

# Compile and build the release
# COPY rel rel
# COPY priv priv
# COPY lib lib
# We need README.md during compilation
# (look for @external_resource "README.md")
# COPY README.md README.md
RUN mix do compile, release

# Stage 2
# Prepares the runtime environment and copies over the relase.
# We use the same base image, because we need Erlang, Elixir and Mix
# during runtime to spawn the Livebook standalone runtimes.
# Consequently the release doesn't include ERTS as we have it anyway.
FROM alpine:3.12.7

COPY --from=final-elixir /usr/local /usr/local
COPY --from=final-erlang /usr/local /usr/local

RUN apk add --no-cache \
    # Runtime dependencies
    openssl ncurses-libs libressl-dev \
    # In case someone uses `Mix.install/2` and point to a git repo
    git

# Run in the /data directory by default, makes for
# a good place for the user to mount local volume
WORKDIR /data

ENV HOME=/home/livebook
# Make sure someone running the container with `--user`
# has permissions to the home dir (for `Mix.install/2` cache)
RUN mkdir $HOME && chmod 777 $HOME

# Install hex and rebar for `Mix.install/2` and Mix runtime
RUN git clone https://github.com/livebook-dev/livebook.git
RUN cp -R livebook/* .
RUN mix local.hex --force && \
    mix local.rebar --force

# Override the default 127.0.0.1 address, so that the app
# can be accessed outside the container by binding ports
ENV LIVEBOOK_IP 0.0.0.0

# Copy the release build from the previous stage
COPY --from=build-livebook /app/_build/prod/rel/livebook /app

# Make release executables available to any user,
# in case someone runs the container with `--user`
RUN find /app -executable -type f -exec chmod +x {} +

CMD [ "/app/bin/livebook", "start" ]
