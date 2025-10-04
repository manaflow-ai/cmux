# syntax=docker/dockerfile:1.7-labs

# Stage 1: Build stage (runs natively on ARM64, cross-compiles to x86_64)
ARG DOCKER_CHANNEL=stable
ARG DOCKER_VERSION
ARG DOCKER_COMPOSE_VERSION
ARG BUILDKIT_VERSION
ARG BUILDX_VERSION
ARG UV_VERSION
ARG PYTHON_VERSION
ARG PIP_VERSION
ARG RUST_VERSION
ARG NVM_VERSION=0.39.7
ARG NODE_VERSION=24.9.0

FROM --platform=$BUILDPLATFORM ubuntu:24.04 AS builder

ARG VERSION
ARG CODE_RELEASE
ARG DOCKER_VERSION
ARG DOCKER_CHANNEL
ARG BUILDPLATFORM
ARG TARGETPLATFORM
ARG UV_VERSION
ARG PYTHON_VERSION
ARG PIP_VERSION
ARG RUST_VERSION
ARG NODE_VERSION
ARG NVM_VERSION

ENV RUSTUP_HOME=/usr/local/rustup \
    CARGO_HOME=/usr/local/cargo \
    NVM_DIR=/root/.nvm \
    PATH="/usr/local/cargo/bin:${PATH}"

# Install build dependencies + cross-compilation toolchain
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    wget \
    git \
    jq \
    python3 \
    make \
    g++ \
    gcc-x86-64-linux-gnu \
    g++-x86-64-linux-gnu \
    libc6-dev-amd64-cross \
    bash \
    unzip \
    xz-utils \
    gnupg

# Install Rust toolchain with x86_64 cross-compilation support
RUN <<'EOF'
set -eux
RUST_VERSION_RAW="${RUST_VERSION:-}"
if [ -z "${RUST_VERSION_RAW}" ]; then
  RUST_VERSION_RAW="$(curl -fsSL https://static.rust-lang.org/dist/channel-rust-stable.toml \
    | awk '/\[pkg.rust\]/{flag=1;next}/\[pkg\./{flag=0}flag && /^version =/ {gsub(/"/,"",$3); split($3, parts, " "); print parts[1]; exit}')"
fi
RUST_VERSION="$(printf '%s' "${RUST_VERSION_RAW}" | tr -d '[:space:]')"
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | \
  sh -s -- -y --no-modify-path --profile minimal --default-toolchain "${RUST_VERSION}"
rustup component add rustfmt --toolchain "${RUST_VERSION}"
rustup target add x86_64-unknown-linux-gnu --toolchain "${RUST_VERSION}"
cargo --version
EOF

# Install Node.js 24.x without relying on external APT mirrors
RUN <<EOF
set -eux
NODE_VERSION="${NODE_VERSION:-24.9.0}"
arch="$(uname -m)"
case "${arch}" in
  x86_64) node_arch="x64" ;;
  aarch64|arm64) node_arch="arm64" ;;
  *) echo "Unsupported architecture: ${arch}" >&2; exit 1 ;;
esac
tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT
cd "${tmp_dir}"
curl -fsSLO "https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-${node_arch}.tar.xz"
curl -fsSLO "https://nodejs.org/dist/v${NODE_VERSION}/SHASUMS256.txt"
grep " node-v${NODE_VERSION}-linux-${node_arch}.tar.xz$" SHASUMS256.txt | sha256sum -c -
tar -xJf "node-v${NODE_VERSION}-linux-${node_arch}.tar.xz" -C /usr/local --strip-components=1
cd /
ln -sf /usr/local/bin/node /usr/bin/node
ln -sf /usr/local/bin/npm /usr/bin/npm
ln -sf /usr/local/bin/npx /usr/bin/npx
ln -sf /usr/local/bin/corepack /usr/bin/corepack
npm install -g node-gyp
corepack enable
corepack prepare pnpm@10.14.0 --activate
EOF

# Install nvm for optional Node version management
RUN <<'EOF'
set -eux
NVM_VERSION="${NVM_VERSION:-0.39.7}"
mkdir -p "${NVM_DIR}"
curl -fsSL "https://raw.githubusercontent.com/nvm-sh/nvm/v${NVM_VERSION}/install.sh" | bash
cat <<'PROFILE' > /etc/profile.d/nvm.sh
export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"
[ -s "$NVM_DIR/bash_completion" ] && . "$NVM_DIR/bash_completion"
PROFILE
bash -lc 'source /etc/profile.d/nvm.sh && nvm --version'
EOF

# Install Bun
RUN curl -fsSL https://bun.sh/install | bash && \
    mv /root/.bun/bin/bun /usr/local/bin/ && \
    ln -s /usr/local/bin/bun /usr/local/bin/bunx && \
    bun --version && \
    bunx --version

# Install openvscode-server (with retries and IPv4 fallback)
RUN if [ -z "${CODE_RELEASE}" ]; then \
    CODE_RELEASE=$(curl -sX GET "https://api.github.com/repos/gitpod-io/openvscode-server/releases/latest" \
    | awk '/tag_name/{print $4;exit}' FS='["\"]' \
    | sed 's|^openvscode-server-v||'); \
    fi && \
    echo "CODE_RELEASE=${CODE_RELEASE}" && \
    arch="$(dpkg --print-architecture)" && \
    if [ "$arch" = "amd64" ]; then \
    ARCH="x64"; \
    elif [ "$arch" = "arm64" ]; then \
    ARCH="arm64"; \
    fi && \
    mkdir -p /app/openvscode-server && \
    url="https://github.com/gitpod-io/openvscode-server/releases/download/openvscode-server-v${CODE_RELEASE}/openvscode-server-v${CODE_RELEASE}-linux-${ARCH}.tar.gz" && \
    echo "Downloading: $url" && \
    ( \
    curl -fSL --retry 6 --retry-all-errors --retry-delay 2 --connect-timeout 20 --max-time 600 -o /tmp/openvscode-server.tar.gz "$url" \
    || curl -fSL4 --retry 6 --retry-all-errors --retry-delay 2 --connect-timeout 20 --max-time 600 -o /tmp/openvscode-server.tar.gz "$url" \
    ) && \
    tar xf /tmp/openvscode-server.tar.gz -C /app/openvscode-server/ --strip-components=1 && \
    rm -rf /tmp/openvscode-server.tar.gz

# Copy package files for monorepo dependency installation
WORKDIR /cmux
COPY package.json bun.lock .npmrc ./
COPY --parents apps/*/package.json packages/*/package.json scripts/package.json ./

RUN --mount=type=cache,target=/root/.bun/install/cache \
    bun install --frozen-lockfile --production

RUN mkdir -p /builtins && \
    echo '{"name":"builtins","type":"module","version":"1.0.0"}' > /builtins/package.json
WORKDIR /builtins

# Copy source files needed for build
WORKDIR /cmux
# Copy shared package source and config
COPY packages/shared/src ./packages/shared/src
COPY packages/shared/tsconfig.json ./packages/shared/

# Copy convex package (needed by shared)
COPY packages/convex ./packages/convex/

# Copy worker source and scripts
COPY apps/worker/src ./apps/worker/src
COPY apps/worker/scripts ./apps/worker/scripts
COPY apps/worker/tsconfig.json ./apps/worker/
COPY apps/worker/wait-for-docker.sh ./apps/worker/

# Copy VS Code extension source
COPY packages/vscode-extension/src ./packages/vscode-extension/src
COPY packages/vscode-extension/tsconfig.json ./packages/vscode-extension/
COPY packages/vscode-extension/.vscodeignore ./packages/vscode-extension/
COPY packages/vscode-extension/LICENSE.md ./packages/vscode-extension/

# Copy vendored Rust crates
COPY crates ./crates

# Build Rust binaries for envctl/envd and cmux-proxy
# Cross-compile to x86_64 only when the target platform requires it
RUN --mount=type=cache,target=/usr/local/cargo/registry \
    --mount=type=cache,target=/usr/local/cargo/git \
    --mount=type=cache,target=/cmux/crates/target \
    if [ "$TARGETPLATFORM" = "linux/amd64" ] && [ "$BUILDPLATFORM" != "linux/amd64" ]; then \
        # Cross-compile to x86_64 when building on a non-amd64 builder
        export CARGO_TARGET_X86_64_UNKNOWN_LINUX_GNU_LINKER=x86_64-linux-gnu-gcc && \
        export CC_x86_64_unknown_linux_gnu=x86_64-linux-gnu-gcc && \
        export CXX_x86_64_unknown_linux_gnu=x86_64-linux-gnu-g++ && \
        cargo install --path crates/cmux-env --target x86_64-unknown-linux-gnu --locked --force && \
        cargo install --path crates/cmux-proxy --target x86_64-unknown-linux-gnu --locked --force; \
    else \
        # Build natively for the requested platform (e.g., arm64 on Apple Silicon)
        cargo install --path crates/cmux-env --locked --force && \
        cargo install --path crates/cmux-proxy --locked --force; \
    fi

# Build worker with bundling, using the installed node_modules
RUN cd /cmux && \
    bun build ./apps/worker/src/index.ts \
    --target node \
    --outdir ./apps/worker/build \
    --external @cmux/convex \
    --external node:* && \
    echo "Built worker" && \
    cp -r ./apps/worker/build /builtins/build && \
    cp ./apps/worker/wait-for-docker.sh /usr/local/bin/ && \
    chmod +x /usr/local/bin/wait-for-docker.sh

# Verify bun is still working in builder
RUN bun --version && bunx --version

# Build vscode extension
WORKDIR /cmux/packages/vscode-extension
RUN bun run package && cp cmux-vscode-extension-0.0.1.vsix /tmp/cmux-vscode-extension-0.0.1.vsix

# Install VS Code extensions (keep the .vsix for copying to runtime-base)
RUN /app/openvscode-server/bin/openvscode-server --install-extension /tmp/cmux-vscode-extension-0.0.1.vsix

# Stage 2: Runtime base (shared between local and morph)
FROM ubuntu:24.04 AS runtime-base

ARG UV_VERSION
ARG PYTHON_VERSION
ARG PIP_VERSION
ARG RUST_VERSION
ARG NODE_VERSION
ARG NVM_VERSION

# Install runtime dependencies only
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    wget \
    git \
    python3 \
    bash \
    nano \
    net-tools \
    lsof \
    sudo \
    iptables \
    openssl \
    pigz \
    xz-utils \
    unzip \
    tmux \
    htop \
    ripgrep \
    jq \
    systemd \
    dbus \
    util-linux

ENV RUSTUP_HOME=/usr/local/rustup \
    CARGO_HOME=/usr/local/cargo \
    NVM_DIR=/root/.nvm \
    PATH="/root/.local/bin:/usr/local/cargo/bin:/usr/local/bin:${PATH}"

# Install uv-managed Python runtime (latest by default) and keep pip pinned
RUN <<'EOF'
set -eux
ARCH="$(uname -m)"
case "${ARCH}" in
  x86_64)
    UV_ASSET_SUFFIX="x86_64-unknown-linux-gnu"
    RUST_HOST_TARGET="x86_64-unknown-linux-gnu"
    ;;
  aarch64)
    UV_ASSET_SUFFIX="aarch64-unknown-linux-gnu"
    RUST_HOST_TARGET="aarch64-unknown-linux-gnu"
    ;;
  *)
    echo "Unsupported architecture: ${ARCH}" >&2
    exit 1
    ;;
esac

UV_VERSION_RAW="${UV_VERSION:-}"
if [ -z "${UV_VERSION_RAW}" ]; then
  UV_VERSION_RAW="$(curl -fsSL https://api.github.com/repos/astral-sh/uv/releases/latest | jq -r '.tag_name')"
fi
UV_VERSION="$(printf '%s' "${UV_VERSION_RAW}" | tr -d ' \t\r\n')"
curl -fsSL "https://github.com/astral-sh/uv/releases/download/${UV_VERSION}/uv-${UV_ASSET_SUFFIX}.tar.gz" -o /tmp/uv.tar.gz
tar -xzf /tmp/uv.tar.gz -C /tmp
install -m 0755 /tmp/uv-${UV_ASSET_SUFFIX}/uv /usr/local/bin/uv
install -m 0755 /tmp/uv-${UV_ASSET_SUFFIX}/uvx /usr/local/bin/uvx
rm -rf /tmp/uv.tar.gz /tmp/uv-${UV_ASSET_SUFFIX}

export PATH="/root/.local/bin:${PATH}"

if [ -n "${PYTHON_VERSION:-}" ]; then
  uv python install "${PYTHON_VERSION}" --default
else
  uv python install --default
fi

PIP_VERSION="${PIP_VERSION:-$(curl -fsSL https://pypi.org/pypi/pip/json | jq -r '.info.version') }"
python3 -m pip install --break-system-packages --upgrade "pip==${PIP_VERSION}"

RUST_VERSION_RAW="${RUST_VERSION:-}"
if [ -z "${RUST_VERSION_RAW}" ]; then
  RUST_VERSION_RAW="$(curl -fsSL https://static.rust-lang.org/dist/channel-rust-stable.toml \
    | awk '/\[pkg.rust\]/{flag=1;next}/\[pkg\./{flag=0}flag && /^version =/ {gsub(/"/,"",$3); split($3, parts, " "); print parts[1]; exit}')"
fi
RUST_VERSION="$(printf '%s' "${RUST_VERSION_RAW}" | tr -d ' \t\r\n')"
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | \
  sh -s -- -y --no-modify-path --profile minimal --default-toolchain "${RUST_VERSION}"
rustup component add rustfmt --toolchain "${RUST_VERSION}"
rustup target add "${RUST_HOST_TARGET}" --toolchain "${RUST_VERSION}"
rustup default "${RUST_VERSION}"
EOF

# Install GitHub CLI
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg | dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg \
    && chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" | tee /etc/apt/sources.list.d/github-cli.list > /dev/null \
    && apt-get update \
    && apt-get install -y gh

# Install Node.js 24.x (runtime) and enable pnpm via corepack
RUN <<EOF
set -eux
NODE_VERSION="${NODE_VERSION:-24.9.0}"
arch="$(uname -m)"
case "${arch}" in
  x86_64) node_arch="x64" ;;
  aarch64|arm64) node_arch="arm64" ;;
  *) echo "Unsupported architecture: ${arch}" >&2; exit 1 ;;
esac
tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT
cd "${tmp_dir}"
curl -fsSLO "https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-${node_arch}.tar.xz"
curl -fsSLO "https://nodejs.org/dist/v${NODE_VERSION}/SHASUMS256.txt"
grep " node-v${NODE_VERSION}-linux-${node_arch}.tar.xz$" SHASUMS256.txt | sha256sum -c -
tar -xJf "node-v${NODE_VERSION}-linux-${node_arch}.tar.xz" -C /usr/local --strip-components=1
cd /
ln -sf /usr/local/bin/node /usr/bin/node
ln -sf /usr/local/bin/npm /usr/bin/npm
ln -sf /usr/local/bin/npx /usr/bin/npx
ln -sf /usr/local/bin/corepack /usr/bin/corepack
corepack enable
corepack prepare pnpm@10.14.0 --activate
EOF

# Install nvm for optional Node version management in runtime
RUN <<'EOF'
set -eux
NVM_VERSION="${NVM_VERSION:-0.39.7}"
mkdir -p "${NVM_DIR}"
curl -fsSL "https://raw.githubusercontent.com/nvm-sh/nvm/v${NVM_VERSION}/install.sh" | bash
cat <<'PROFILE' > /etc/profile.d/nvm.sh
export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"
[ -s "$NVM_DIR/bash_completion" ] && . "$NVM_DIR/bash_completion"
PROFILE
bash -lc 'source /etc/profile.d/nvm.sh && nvm --version'
EOF

# Install Bun natively (since runtime is x86_64, we can't copy from ARM64 builder)
RUN curl -fsSL https://bun.sh/install | bash && \
    mv /root/.bun/bin/bun /usr/local/bin/ && \
    ln -s /usr/local/bin/bun /usr/local/bin/bunx && \
    bun --version && \
    bunx --version

ENV PATH="/usr/local/bin:$PATH"

RUN --mount=type=cache,target=/root/.bun/install/cache \
    bun add -g @openai/codex@0.42.0 @anthropic-ai/claude-code@2.0.0 @google/gemini-cli@0.1.21 opencode-ai@0.6.4 codebuff @devcontainers/cli @sourcegraph/amp

# Install cursor cli
RUN curl https://cursor.com/install -fsS | bash
RUN /root/.local/bin/cursor-agent --version

# Copy only the built artifacts and runtime dependencies from builder
# Note: We need to install openvscode-server for the target arch (x86_64), not copy from ARM64 builder
COPY --from=builder /builtins /builtins
COPY --from=builder /usr/local/bin/wait-for-docker.sh /usr/local/bin/wait-for-docker.sh
COPY apps/worker/scripts/collect-relevant-diff.sh /usr/local/bin/cmux-collect-relevant-diff.sh
COPY apps/worker/scripts/collect-crown-diff.sh /usr/local/bin/cmux-collect-crown-diff.sh
RUN chmod +x /usr/local/bin/cmux-collect-relevant-diff.sh \
    && chmod +x /usr/local/bin/cmux-collect-crown-diff.sh

# Install openvscode-server for x86_64 (target platform)
ARG CODE_RELEASE
RUN if [ -z "${CODE_RELEASE}" ]; then \
    CODE_RELEASE=$(curl -sX GET "https://api.github.com/repos/gitpod-io/openvscode-server/releases/latest" \
    | awk '/tag_name/{print $4;exit}' FS='["\"]' \
    | sed 's|^openvscode-server-v||'); \
    fi && \
    echo "CODE_RELEASE=${CODE_RELEASE}" && \
    arch="$(dpkg --print-architecture)" && \
    if [ "$arch" = "amd64" ]; then \
    ARCH="x64"; \
    elif [ "$arch" = "arm64" ]; then \
    ARCH="arm64"; \
    fi && \
    mkdir -p /app/openvscode-server && \
    url="https://github.com/gitpod-io/openvscode-server/releases/download/openvscode-server-v${CODE_RELEASE}/openvscode-server-v${CODE_RELEASE}-linux-${ARCH}.tar.gz" && \
    echo "Downloading: $url" && \
    ( \
    curl -fSL --retry 6 --retry-all-errors --retry-delay 2 --connect-timeout 20 --max-time 600 -o /tmp/openvscode-server.tar.gz "$url" \
    || curl -fSL4 --retry 6 --retry-all-errors --retry-delay 2 --connect-timeout 20 --max-time 600 -o /tmp/openvscode-server.tar.gz "$url" \
    ) && \
    tar xf /tmp/openvscode-server.tar.gz -C /app/openvscode-server/ --strip-components=1 && \
    rm -rf /tmp/openvscode-server.tar.gz

# Copy the cmux vscode extension from builder (it's just a .vsix file, platform-independent)
COPY --from=builder /tmp/cmux-vscode-extension-0.0.1.vsix /tmp/cmux-vscode-extension-0.0.1.vsix
RUN /app/openvscode-server/bin/openvscode-server --install-extension /tmp/cmux-vscode-extension-0.0.1.vsix && \
    rm /tmp/cmux-vscode-extension-0.0.1.vsix

# Copy vendored Rust binaries from builder
COPY --from=builder /usr/local/cargo/bin/envctl /usr/local/bin/envctl
COPY --from=builder /usr/local/cargo/bin/envd /usr/local/bin/envd
COPY --from=builder /usr/local/cargo/bin/cmux-proxy /usr/local/bin/cmux-proxy

# Configure envctl/envd runtime defaults
RUN chmod +x /usr/local/bin/envctl /usr/local/bin/envd /usr/local/bin/cmux-proxy && \
    envctl --version && \
    envctl install-hook bash && \
    echo '[ -f ~/.bashrc ] && . ~/.bashrc' > /root/.profile && \
    echo '[ -f ~/.bashrc ] && . ~/.bashrc' > /root/.bash_profile && \
    mkdir -p /run/user/0 && \
    chmod 700 /run/user/0 && \
    echo 'export XDG_RUNTIME_DIR=/run/user/0' >> /root/.bashrc

# Install tmux configuration for better mouse scrolling behavior
COPY configs/tmux.conf /etc/tmux.conf

# Install Claude Code extension v2.0.0 from VS Code Marketplace
# The vspackage endpoint returns a gzipped vsix, so we need to decompress it first
RUN wget --retry-connrefused --waitretry=1 --read-timeout=20 --timeout=15 -t 5 \
    "https://marketplace.visualstudio.com/_apis/public/gallery/publishers/anthropic/vsextensions/claude-code/2.0.0/vspackage" \
    -O /tmp/claude-code.vsix.gz && \
    gunzip /tmp/claude-code.vsix.gz && \
    /app/openvscode-server/bin/openvscode-server --install-extension /tmp/claude-code.vsix && \
    rm /tmp/claude-code.vsix

# Create workspace and lifecycle directories
RUN mkdir -p /workspace /root/workspace /root/lifecycle

COPY prompt-wrapper.sh /usr/local/bin/prompt-wrapper
RUN chmod +x /usr/local/bin/prompt-wrapper

# Install cmux systemd units and helpers
RUN mkdir -p /usr/local/lib/cmux
COPY configs/systemd/cmux.target /usr/lib/systemd/system/cmux.target
COPY configs/systemd/cmux-openvscode.service /usr/lib/systemd/system/cmux-openvscode.service
COPY configs/systemd/cmux-worker.service /usr/lib/systemd/system/cmux-worker.service
COPY configs/systemd/cmux-dockerd.service /usr/lib/systemd/system/cmux-dockerd.service
COPY configs/systemd/bin/configure-openvscode /usr/local/lib/cmux/configure-openvscode
COPY configs/systemd/bin/cmux-rootfs-exec /usr/local/lib/cmux/cmux-rootfs-exec
RUN chmod +x /usr/local/lib/cmux/configure-openvscode /usr/local/lib/cmux/cmux-rootfs-exec && \
    touch /usr/local/lib/cmux/dockerd.flag && \
    mkdir -p /var/log/cmux && \
    mkdir -p /etc/systemd/system/multi-user.target.wants && \
    mkdir -p /etc/systemd/system/cmux.target.wants && \
    ln -sf /usr/lib/systemd/system/cmux.target /etc/systemd/system/multi-user.target.wants/cmux.target && \
    ln -sf /usr/lib/systemd/system/cmux-openvscode.service /etc/systemd/system/cmux.target.wants/cmux-openvscode.service && \
    ln -sf /usr/lib/systemd/system/cmux-worker.service /etc/systemd/system/cmux.target.wants/cmux-worker.service && \
    ln -sf /usr/lib/systemd/system/cmux-dockerd.service /etc/systemd/system/cmux.target.wants/cmux-dockerd.service && \
    mkdir -p /opt/app/overlay/upper /opt/app/overlay/work && \
    printf 'CMUX_ROOTFS=/\nCMUX_RUNTIME_ROOT=/\nCMUX_OVERLAY_UPPER=/opt/app/overlay/upper\nCMUX_OVERLAY_WORK=/opt/app/overlay/work\n' > /opt/app/app.env

# Create VS Code user settings
RUN mkdir -p /root/.openvscode-server/data/User && \
    echo '{\"workbench.startupEditor\": \"none\", \"terminal.integrated.macOptionClickForcesSelection\": true, \"terminal.integrated.shell.linux\": \"bash\", \"terminal.integrated.shellArgs.linux\": [\"-l\"]}' > /root/.openvscode-server/data/User/settings.json && \
    mkdir -p /root/.openvscode-server/data/User/profiles/default-profile && \
    echo '{\"workbench.startupEditor\": \"none\", \"terminal.integrated.macOptionClickForcesSelection\": true, \"terminal.integrated.shell.linux\": \"bash\", \"terminal.integrated.shellArgs.linux\": [\"-l\"]}' > /root/.openvscode-server/data/User/profiles/default-profile/settings.json && \
    mkdir -p /root/.openvscode-server/data/Machine && \
    echo '{\"workbench.startupEditor\": \"none\", \"terminal.integrated.macOptionClickForcesSelection\": true, \"terminal.integrated.shell.linux\": \"bash\", \"terminal.integrated.shellArgs.linux\": [\"-l\"]}' > /root/.openvscode-server/data/Machine/settings.json

# Ports
# 39376: VS Code Extension Socket Server
# 39377: Worker service
# 39378: OpenVSCode server
# 39379: cmux-proxy
EXPOSE 39376 39377 39378 39379

ENV container=docker
STOPSIGNAL SIGRTMIN+3
VOLUME [ "/sys/fs/cgroup" ]
WORKDIR /
ENTRYPOINT ["/usr/lib/systemd/systemd"]
CMD []

# Stage 3: Local (DinD) runtime with Docker available
FROM runtime-base AS runtime-local

ARG DOCKER_VERSION
ARG DOCKER_CHANNEL
ARG DOCKER_COMPOSE_VERSION
ARG BUILDX_VERSION
ARG BUILDKIT_VERSION

# Switch to legacy iptables for Docker compatibility
RUN update-alternatives --set iptables /usr/sbin/iptables-legacy

# Install Docker
RUN <<-'EOF'
    set -eux; \
    arch="$(uname -m)"; \
    DOCKER_CHANNEL="${DOCKER_CHANNEL:-stable}"; \
    DOCKER_VERSION="${DOCKER_VERSION:-$(curl -fsSL https://api.github.com/repos/docker/docker/releases/latest | jq -r '.tag_name' | sed 's/^v//')}"; \
    case "$arch" in \
        x86_64) dockerArch='x86_64' ;; \
        aarch64) dockerArch='aarch64' ;; \
        *) echo >&2 "error: unsupported architecture ($arch)"; exit 1 ;; \
    esac; \
    wget -O docker.tgz "https://download.docker.com/linux/static/${DOCKER_CHANNEL}/${dockerArch}/docker-${DOCKER_VERSION}.tgz"; \
    tar --extract --file docker.tgz --strip-components 1 --directory /usr/local/bin/; \
    rm docker.tgz; \
    dockerd --version || echo "dockerd --version failed (ignored during build)"; \
    docker --version || echo "docker --version failed (ignored during build)"
EOF

# Install Docker Compose, Buildx, and BuildKit
RUN <<-'EOF'
    set -eux; \
    mkdir -p /usr/local/lib/docker/cli-plugins; \
    arch="$(uname -m)"; \
    case "$arch" in \
        x86_64) composeArch='x86_64'; buildxAsset='linux-amd64'; buildkitAsset='linux-amd64' ;; \
        aarch64) composeArch='aarch64'; buildxAsset='linux-arm64'; buildkitAsset='linux-arm64' ;; \
        *) echo >&2 "error: unsupported architecture ($arch)"; exit 1 ;; \
    esac; \
    DOCKER_COMPOSE_VERSION="${DOCKER_COMPOSE_VERSION:-$(curl -fsSL https://api.github.com/repos/docker/compose/releases/latest | jq -r '.tag_name' | sed 's/^v//')}"; \
    curl -fsSL "https://github.com/docker/compose/releases/download/v${DOCKER_COMPOSE_VERSION}/docker-compose-linux-${composeArch}" \
        -o /usr/local/lib/docker/cli-plugins/docker-compose; \
    chmod +x /usr/local/lib/docker/cli-plugins/docker-compose; \
    BUILDX_VERSION="${BUILDX_VERSION:-$(curl -fsSL https://api.github.com/repos/docker/buildx/releases/latest | jq -r '.tag_name' | sed 's/^v//')}"; \
    curl -fsSL "https://github.com/docker/buildx/releases/download/v${BUILDX_VERSION}/buildx-v${BUILDX_VERSION}.${buildxAsset}" \
        -o /usr/local/lib/docker/cli-plugins/docker-buildx; \
    chmod +x /usr/local/lib/docker/cli-plugins/docker-buildx; \
    BUILDKIT_VERSION="${BUILDKIT_VERSION:-$(curl -fsSL https://api.github.com/repos/moby/buildkit/releases/latest | jq -r '.tag_name' | sed 's/^v//')}"; \
    curl -fsSL "https://github.com/moby/buildkit/releases/download/v${BUILDKIT_VERSION}/buildkit-v${BUILDKIT_VERSION}.${buildkitAsset}.tar.gz" \
        -o /tmp/buildkit.tar.gz; \
    tar -xzf /tmp/buildkit.tar.gz -C /tmp; \
    install -m 0755 /tmp/bin/buildctl /usr/local/bin/buildctl; \
    install -m 0755 /tmp/bin/buildkitd /usr/local/bin/buildkitd; \
    rm -rf /tmp/buildkit.tar.gz /tmp/bin; \
    docker compose version || true; \
    docker buildx version || true; \
    buildctl --version || true
EOF

# Create modprobe script (required for DinD)
RUN <<-'EOF'
cat > /usr/local/bin/modprobe << 'SCRIPT'
#!/bin/sh
set -eu
# "modprobe" without modprobe
for module; do
    if [ "${module#-}" = "$module" ]; then
        ip link show "$module" || true
        lsmod | grep "$module" || true
    fi
done
# remove /usr/local/... from PATH so we can exec the real modprobe as a last resort
export PATH='/usr/sbin:/usr/bin:/sbin:/bin'
exec modprobe "$@"
SCRIPT
chmod +x /usr/local/bin/modprobe
EOF

VOLUME /var/lib/docker

# Create supervisor config for dockerd
# Based on https://github.com/cruizba/ubuntu-dind
RUN <<-'EOF'
mkdir -p /etc/supervisor/conf.d
cat > /etc/supervisor/conf.d/dockerd.conf << 'CONFIG'
[program:dockerd]
command=/usr/local/bin/dockerd
autostart=true
autorestart=true
stderr_logfile=/var/log/dockerd.err.log
stdout_logfile=/var/log/dockerd.out.log
CONFIG
EOF

# Stage 4: Morph runtime without Docker
FROM runtime-base AS morph

# Final image (default) uses the local DinD runtime
FROM runtime-local
