FROM golang:1.25-bookworm AS go-toolchain
FROM node:24-bookworm

ENV DEBIAN_FRONTEND=noninteractive \
    PATH=/usr/local/go/bin:$PATH \
    GOTOOLCHAIN=local \
    GOFLAGS=-buildvcs=false
COPY --from=go-toolchain /usr/local/go /usr/local/go
RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates clang cmake git ninja-build openssh-client pkg-config \
      python3 python3-venv ripgrep tmux \
    && rm -rf /var/lib/apt/lists/* \
    && npm install --global bun@1.4.2

# Keep source available to the scanner while avoiding a multi-gigabyte Git
# object database in the image. The scanner records the cloned revision.
COPY . /src
WORKDIR /src
RUN rm -rf /src/.git && mkdir -p /src/.git \
    && printf 'gitdir: /src/.git\n' > /src/.git/config

# Portable SSH/Cloud daemon and its offline test dependencies.
RUN cd daemon/remote \
    && go mod download \
    && go build -o /usr/local/bin/cmuxd-remote ./cmd/cmuxd-remote \
    && go test ./... -count=1 -timeout=180s

# Prepare JavaScript dependencies for offline source analysis.
RUN bun install --cwd /src --frozen-lockfile \
    && bun install --cwd /src/web --frozen-lockfile \
    && bun install --cwd /src/webviews --frozen-lockfile

ENV GOPROXY=off
WORKDIR /src
CMD ["bash"]
