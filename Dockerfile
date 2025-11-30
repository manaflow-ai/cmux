# syntax=docker/dockerfile:1.7-labs

# Stage 1: Rust build stage
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
ARG GO_VERSION=1.25.2
ARG GITHUB_TOKEN

FROM --platform=$BUILDPLATFORM ubuntu:24.04 AS rust-builder

ARG RUST_VERSION
ARG BUILDPLATFORM
ARG TARGETPLATFORM

ENV RUSTUP_HOME=/usr/local/rustup \
  CARGO_HOME=/usr/local/cargo \
  PATH="/usr/local/cargo/bin:${PATH}"

# Install minimal dependencies for Rust cross-compilation
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
  --mount=type=cache,target=/var/lib/apt,sharing=locked \
  apt-get update && apt-get install -y --no-install-recommends \
  ca-certificates \
  curl \
  gcc \
  g++ \
  libc6-dev \
  gcc-x86-64-linux-gnu \
  g++-x86-64-linux-gnu \
  libc6-dev-amd64-cross

# Install Rust toolchain with x86_64 cross-compilation support
RUN bash <<'EOF'
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

WORKDIR /cmux

# Copy only Rust crates
COPY crates ./crates

# Build Rust binaries
RUN --mount=type=cache,target=/usr/local/cargo/registry \
  --mount=type=cache,target=/usr/local/cargo/git \
  --mount=type=cache,target=/cmux/crates/target \
  if [ "$TARGETPLATFORM" = "linux/amd64" ] && [ "$BUILDPLATFORM" != "linux/amd64" ]; then \
  # Cross-compile to x86_64 when building on a non-amd64 builder
  export CARGO_TARGET_X86_64_UNKNOWN_LINUX_GNU_LINKER=x86_64-linux-gnu-gcc && \
  export CC_x86_64_unknown_linux_gnu=x86_64-linux-gnu-gcc && \
  export CXX_x86_64_unknown_linux_gnu=x86_64-linux-gnu-g++ && \
  cargo install --path crates/cmux-env --target x86_64-unknown-linux-gnu --locked --force && \
  cargo install --path crates/cmux-proxy --target x86_64-unknown-linux-gnu --locked --force && \
  cargo install --path crates/cmux-xterm --target x86_64-unknown-linux-gnu --locked --force; \
  else \
  # Build natively for the requested platform (e.g., arm64 on Apple Silicon)
  cargo install --path crates/cmux-env --locked --force && \
  cargo install --path crates/cmux-proxy --locked --force && \
  cargo install --path crates/cmux-xterm --locked --force; \
  fi

# Stage 2: Build base stage (runs natively on ARM64, cross-compiles to x86_64)
FROM --platform=$BUILDPLATFORM ubuntu:24.04 AS builder-base

ARG GITHUB_TOKEN

ARG VERSION
ARG CODE_RELEASE=1.103.1
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
ARG GO_VERSION

ENV NVM_DIR=/root/.nvm \
  PATH="/usr/local/bin:${PATH}"

# Install build dependencies (Rust is in rust-builder stage)
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
  bash \
  zsh \
  unzip \
  xz-utils \
  gnupg \
  ruby-full \
  perl

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

# Install Go toolchain for building helper binaries
RUN <<'EOF'
set -eux
GO_VERSION="${GO_VERSION:-1.25.2}"
arch="$(uname -m)"
case "${arch}" in
  x86_64) go_arch="amd64" ;;
  aarch64|arm64) go_arch="arm64" ;;
  *) echo "Unsupported architecture for Go: ${arch}" >&2; exit 1 ;;
esac
tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT
cd "${tmp_dir}"
curl -fsSLo go.tar.gz "https://go.dev/dl/go${GO_VERSION}.linux-${go_arch}.tar.gz"
rm -rf /usr/local/go
tar -C /usr/local -xzf go.tar.gz
ln -sf /usr/local/go/bin/go /usr/local/bin/go
ln -sf /usr/local/go/bin/gofmt /usr/local/bin/gofmt
/usr/local/go/bin/go version
EOF

# Helper script for authenticated GitHub downloads
RUN <<'EOF'
set -eux
cat <<'SCRIPT' >/usr/local/bin/github-curl
#!/usr/bin/env bash
set -euo pipefail
token="${GITHUB_TOKEN:-}"
if [ -z "${token}" ] && [ -f /run/secrets/github_token ]; then
  token="$(tr -d '\r\n' </run/secrets/github_token)"
fi
if [ -n "${token}" ]; then
  exec curl -H "Authorization: Bearer ${token}" "$@"
fi
exec curl "$@"
SCRIPT
chmod +x /usr/local/bin/github-curl
EOF

# Install nvm for optional Node version management
RUN --mount=type=secret,id=github_token,required=false bash <<'EOF'
set -eux
NVM_VERSION="${NVM_VERSION:-0.39.7}"
mkdir -p "${NVM_DIR}"
github-curl -fsSL "https://raw.githubusercontent.com/nvm-sh/nvm/v${NVM_VERSION}/install.sh" | bash
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
RUN --mount=type=secret,id=github_token,required=false if [ -z "${CODE_RELEASE}" ]; then \
  CODE_RELEASE=$(github-curl -sX GET "https://api.github.com/repos/gitpod-io/openvscode-server/releases/latest" \
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
  github-curl -fSL --retry 6 --retry-all-errors --retry-delay 2 --connect-timeout 20 --max-time 600 -o /tmp/openvscode-server.tar.gz "$url" \
  || github-curl -4 -fSL --retry 6 --retry-all-errors --retry-delay 2 --connect-timeout 20 --max-time 600 -o /tmp/openvscode-server.tar.gz "$url" \
  ) && \
  tar xf /tmp/openvscode-server.tar.gz -C /app/openvscode-server/ --strip-components=1 && \
  rm -rf /tmp/openvscode-server.tar.gz

# Copy package files for monorepo dependency installation
WORKDIR /cmux
ENV BUN_INSTALL_CACHE_DIR=/cmux/node_modules/.bun
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

# Copy Chrome DevTools proxy source
COPY scripts/cdp-proxy ./scripts/cdp-proxy/
# Copy VNC websocket proxy source
COPY scripts/vnc-proxy ./scripts/vnc-proxy/

# Build Chrome DevTools proxy binary
RUN --mount=type=cache,target=/root/.cache/go-build \
  --mount=type=cache,target=/go/pkg/mod \
  <<'EOF'
set -eux
mkdir -p /usr/local/lib/cmux
export PATH="/usr/local/go/bin:${PATH}"
case "${TARGETPLATFORM:-}" in
  linux/amd64 | linux/amd64/*)
    export GOOS=linux
    export GOARCH=amd64
    ;;
  linux/arm64 | linux/arm64/*)
    export GOOS=linux
    export GOARCH=arm64
    ;;
  *)
    echo "Unsupported TARGETPLATFORM: ${TARGETPLATFORM:-}" >&2
    exit 1
    ;;
esac
export CGO_ENABLED=0
cd /cmux/scripts/cdp-proxy
go build -trimpath -ldflags="-s -w" -o /usr/local/lib/cmux/cmux-cdp-proxy .
test -x /usr/local/lib/cmux/cmux-cdp-proxy
EOF

# Build VNC websocket proxy binary
RUN --mount=type=cache,target=/root/.cache/go-build \
  --mount=type=cache,target=/go/pkg/mod \
  <<'EOF'
set -eux
mkdir -p /usr/local/lib/cmux
export PATH="/usr/local/go/bin:${PATH}"
case "${TARGETPLATFORM:-}" in
  linux/amd64 | linux/amd64/*)
    export GOOS=linux
    export GOARCH=amd64
    ;;
  linux/arm64 | linux/arm64/*)
    export GOOS=linux
    export GOARCH=arm64
    ;;
  *)
    echo "Unsupported TARGETPLATFORM: ${TARGETPLATFORM:-}" >&2
    exit 1
    ;;
esac
export CGO_ENABLED=0
cd /cmux/scripts/vnc-proxy
go build -trimpath -ldflags="-s -w" -o /usr/local/lib/cmux/cmux-vnc-proxy .
test -x /usr/local/lib/cmux/cmux-vnc-proxy
EOF

# Verify bun is still working in builder
RUN bun --version && bunx --version

# Copy VS Code extension source
COPY packages/vscode-extension/src ./packages/vscode-extension/src
COPY packages/vscode-extension/tsconfig.json ./packages/vscode-extension/
COPY packages/vscode-extension/.vscodeignore ./packages/vscode-extension/
COPY packages/vscode-extension/LICENSE.md ./packages/vscode-extension/

# Build vscode extension
WORKDIR /cmux/packages/vscode-extension
RUN bun run package && cp cmux-vscode-extension-0.0.1.vsix /tmp/cmux-vscode-extension-0.0.1.vsix

# Install VS Code extensions (keep the .vsix for copying to runtime-base)
RUN /app/openvscode-server/bin/openvscode-server --install-extension /tmp/cmux-vscode-extension-0.0.1.vsix

# Stage 2b: Worker build stage
FROM builder-base AS builder

# Return to repo root before copying worker sources
WORKDIR /cmux

# Copy worker source and scripts
COPY apps/worker/src ./apps/worker/src
COPY apps/worker/scripts ./apps/worker/scripts
COPY apps/worker/tsconfig.json ./apps/worker/
COPY apps/worker/wait-for-docker.sh ./apps/worker/

# Build worker with bundling, using the installed node_modules
RUN bash <<'EOF'
set -euo pipefail
cd /cmux
bun build ./apps/worker/src/index.ts \
  --target node \
  --outdir ./apps/worker/build \
  --external @cmux/convex \
  --external convex \
  --external node:*
bun build ./apps/worker/src/runBrowserAgentFromPrompt.ts \
  --target node \
  --outdir ./apps/worker/build/browser-agent \
  --external magnitude-core \
  --external @cmux/convex \
  --external convex \
  --external node:*
mv ./apps/worker/build/browser-agent/runBrowserAgentFromPrompt.js ./apps/worker/build/runBrowserAgentFromPrompt.js
rm -rf ./apps/worker/build/browser-agent
echo "Built worker"
mkdir -p ./apps/worker/build/node_modules
shopt -s nullglob
declare -A COPIED_PACKAGES=()

sanitize_package_name() {
  local package="$1"
  if [[ "$package" == @*/* ]]; then
    local scope="${package%%/*}"
    local name="${package#*/}"
    printf '%s+%s' "$scope" "$name"
  else
    printf '%s' "$package"
  fi
}

copy_scope_directory() {
  local source_dir="$1"
  local scope_name
  scope_name="$(basename "$source_dir")"
  mkdir -p "./apps/worker/build/node_modules/$scope_name"
  for scoped_entry in "$source_dir"/*; do
    if [ ! -e "$scoped_entry" ]; then
      continue
    fi
    local scoped_name
    scoped_name="$(basename "$scoped_entry")"
    rm -rf "./apps/worker/build/node_modules/$scope_name/$scoped_name"
    cp -RL "$scoped_entry" "./apps/worker/build/node_modules/$scope_name/$scoped_name"
  done
}

copy_bundle_directory() {
  local bundle_dir="$1"
  for entry in "$bundle_dir"/*; do
    if [ ! -d "$entry" ]; then
      continue
    fi
    local entry_name
    entry_name="$(basename "$entry")"
    if [[ "$entry_name" == @* ]]; then
      copy_scope_directory "$entry"
    else
      rm -rf "./apps/worker/build/node_modules/$entry_name"
      cp -RL "$entry" "./apps/worker/build/node_modules/$entry_name"
    fi
  done
}

copy_dependency_tree() {
  local package="$1"
  if [[ -n "${COPIED_PACKAGES[$package]:-}" ]]; then
    return
  fi
  COPIED_PACKAGES["$package"]=1

  local sanitized
  sanitized="$(sanitize_package_name "$package")"
  local found=false

  for bundle_dir in node_modules/.bun/"${sanitized}"@*/node_modules; do
    if [ ! -d "$bundle_dir" ]; then
      continue
    fi
    found=true
    copy_bundle_directory "$bundle_dir"
    local module_path="$bundle_dir/$package"
    if [ ! -d "$module_path" ] || [ ! -f "$module_path/package.json" ]; then
      continue
    fi
    mapfile -t dependency_specs < <(jq -r '
      [
        (.dependencies // {} | to_entries[] | "\(.key)\t\(.value)"),
        (.optionalDependencies // {} | to_entries[] | "\(.key)\t\(.value)"),
        (.peerDependencies // {} | to_entries[] | "\(.key)\t\(.value)")
      ]
      | flatten
      | unique
      | .[]
    ' "$module_path/package.json" 2>/dev/null || true)
    for spec in "${dependency_specs[@]}"; do
      IFS=$'\t' read -r dependency_name dependency_version <<<"$spec"
      if [[ -z "$dependency_name" ]]; then
        continue
      fi
      if [[ "$dependency_name" == "fsevents" ]]; then
        continue
      fi
      local resolved_name="$dependency_name"
      if [[ "$dependency_version" == npm:* ]]; then
        local remainder="${dependency_version#npm:}"
        if [[ "$remainder" == *@* ]]; then
          resolved_name="${remainder%@*}"
        else
          resolved_name="$remainder"
        fi
      elif [[ "$dependency_version" == "workspace:"* || "$dependency_version" == "file:"* ]]; then
        continue
      fi
      copy_dependency_tree "$resolved_name"
    done
  done

  if [ "$found" = false ]; then
    echo "Warning: package $package not found in Bun cache" >&2
  fi
}

copy_dependency_tree "magnitude-core"
cp -r ./apps/worker/build /builtins/build
cp ./apps/worker/wait-for-docker.sh /usr/local/bin/
chmod +x /usr/local/bin/wait-for-docker.sh
EOF

# Stage 2: Runtime base (shared between local and morph)
FROM ubuntu:24.04 AS runtime-base

ARG GITHUB_TOKEN

COPY --from=builder /usr/local/bin/github-curl /usr/local/bin/github-curl

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
  kmod \
  util-linux \
  tigervnc-standalone-server \
  tigervnc-common \
  xvfb \
  fluxbox \
  novnc \
  xauth \
  xdg-utils \
  socat \
  fonts-liberation \
  libasound2t64 \
  libatk-bridge2.0-0 \
  libatspi2.0-0 \
  libcups2 \
  libdrm2 \
  libgbm1 \
  libgtk-3-0 \
  libnspr4 \
  libnss3 \
  libpango-1.0-0 \
  libx11-xcb1 \
  libxcomposite1 \
  libxcursor1 \
  libxdamage1 \
  libxfixes3 \
  libxi6 \
  libxkbcommon0 \
  libxrandr2 \
  libxrender1 \
  libxshmfence1 \
  libxss1 \
  libxtst6 \
  zram-tools

ENV RUSTUP_HOME=/usr/local/rustup \
  CARGO_HOME=/usr/local/cargo \
  NVM_DIR=/root/.nvm \
  PATH="/root/.local/bin:/usr/local/cargo/bin:/usr/local/bin:${PATH}"

# Install Chrome (amd64) or Chromium snapshot (arm64) so that VNC sessions have a browser available
RUN --mount=type=secret,id=github_token,required=false <<'EOF'
set -eux
arch="$(dpkg --print-architecture)"
tmp_dir="$(mktemp -d)"
cleanup() {
  rm -rf "${tmp_dir}"
}
trap cleanup EXIT

case "${arch}" in
  amd64)
    cd "${tmp_dir}"
    curl -fsSLo chrome.deb https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb
    if ! apt-get install -y --no-install-recommends ./chrome.deb; then
      apt-get install -y --no-install-recommends -f
      apt-get install -y --no-install-recommends ./chrome.deb
    fi
    ln -sf /usr/bin/google-chrome-stable /usr/local/bin/google-chrome
    ln -sf /usr/bin/google-chrome-stable /usr/local/bin/chromium-browser
    ln -sf /usr/bin/google-chrome-stable /usr/local/bin/chrome
    ;;
  arm64)
    cd "${tmp_dir}"
    revision="$(github-curl -fsSL https://raw.githubusercontent.com/microsoft/playwright/main/packages/playwright-core/browsers.json \
      | jq -r '.browsers[] | select(.name == "chromium") | .revision')"
    if [ -z "${revision}" ] || [ "${revision}" = "null" ]; then
      echo "Failed to determine Playwright Chromium revision for arm64" >&2
      exit 1
    fi
    curl -fsSLo chrome.zip "https://playwright.azureedge.net/builds/chromium/${revision}/chromium-linux-arm64.zip"
    unzip -q chrome.zip
    install_dir=/opt/chromium-linux-arm64
    rm -rf "${install_dir}"
    mv chrome-linux "${install_dir}"
    ln -sf "${install_dir}/chrome" /usr/local/bin/chromium-browser
    ln -sf "${install_dir}/chrome" /usr/local/bin/google-chrome
    ln -sf "${install_dir}/chrome" /usr/local/bin/chrome
    ;;
  *)
    echo "Unsupported architecture for Chrome installation: ${arch}" >&2
    exit 1
    ;;
esac
EOF


# Install uv-managed Python runtime (latest by default) and keep pip pinned
RUN --mount=type=secret,id=github_token,required=false <<'EOF'
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
  UV_VERSION_RAW="$(github-curl -fsSL https://api.github.com/repos/astral-sh/uv/releases/latest | jq -r '.tag_name')"
fi
UV_VERSION="$(printf '%s' "${UV_VERSION_RAW}" | tr -d ' \t\r\n')"
github-curl -fsSL "https://github.com/astral-sh/uv/releases/download/${UV_VERSION}/uv-${UV_ASSET_SUFFIX}.tar.gz" -o /tmp/uv.tar.gz
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

# Install GitHub CLI using repo enabler
COPY scripts/repo-enablers /usr/local/share/cmux/repo-enablers
RUN find /usr/local/share/cmux/repo-enablers -type f -name '*.sh' -exec chmod +x {} +
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
  --mount=type=cache,target=/var/lib/apt,sharing=locked \
  --mount=type=secret,id=github_token,required=false \
  /usr/local/share/cmux/repo-enablers/deb/github-cli.sh \
  && DEBIAN_FRONTEND=noninteractive apt-get update \
  && DEBIAN_FRONTEND=noninteractive apt-get install -y gh \
  && rm -rf /var/lib/apt/lists/*

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
RUN --mount=type=secret,id=github_token,required=false <<'EOF'
set -eux
NVM_VERSION="${NVM_VERSION:-0.39.7}"
mkdir -p "${NVM_DIR}"
github-curl -fsSL "https://raw.githubusercontent.com/nvm-sh/nvm/v${NVM_VERSION}/install.sh" | bash
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
ENV BUN_INSTALL_CACHE_DIR=/cmux/node_modules/.bun

RUN --mount=type=cache,target=/root/.bun/install/cache \
  bun add -g @openai/codex@0.50.0 @anthropic-ai/claude-code@2.0.54 @google/gemini-cli@0.1.21 opencode-ai@0.6.4 codebuff @devcontainers/cli @sourcegraph/amp

# Install cursor cli
RUN curl https://cursor.com/install -fsS | bash
RUN /root/.local/bin/cursor-agent --version

# Copy only the built artifacts and runtime dependencies from builder
# Note: We need to install openvscode-server for the target arch (x86_64), not copy from ARM64 builder
COPY --from=builder /builtins /builtins
COPY --from=builder /cmux/node_modules/.bun /cmux/node_modules/.bun
COPY --from=builder /usr/local/bin/wait-for-docker.sh /usr/local/bin/wait-for-docker.sh

# Install openvscode-server for x86_64 (target platform)
ARG CODE_RELEASE
RUN --mount=type=secret,id=github_token,required=false if [ -z "${CODE_RELEASE}" ]; then \
  CODE_RELEASE=$(github-curl -sX GET "https://api.github.com/repos/gitpod-io/openvscode-server/releases/latest" \
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
  github-curl -fSL --retry 6 --retry-all-errors --retry-delay 2 --connect-timeout 20 --max-time 600 -o /tmp/openvscode-server.tar.gz "$url" \
  || github-curl -4 -fSL --retry 6 --retry-all-errors --retry-delay 2 --connect-timeout 20 --max-time 600 -o /tmp/openvscode-server.tar.gz "$url" \
  ) && \
  tar xf /tmp/openvscode-server.tar.gz -C /app/openvscode-server/ --strip-components=1 && \
  rm -rf /tmp/openvscode-server.tar.gz

# Copy the cmux vscode extension from builder (it's just a .vsix file, platform-independent)
COPY --from=builder /tmp/cmux-vscode-extension-0.0.1.vsix /tmp/cmux-vscode-extension-0.0.1.vsix
RUN <<'EOF'
set -eux
export HOME=/root
server_root="/app/openvscode-server"
bin_path="${server_root}/bin/openvscode-server"
if [ ! -x "${bin_path}" ]; then
  echo "OpenVSCode binary not found at ${bin_path}" >&2
  exit 1
fi
extensions_dir="/root/.openvscode-server/extensions"
user_data_dir="/root/.openvscode-server/data"
mkdir -p "${extensions_dir}" "${user_data_dir}"
install_from_file() {
  package_path="$1"
  "${bin_path}" \
    --install-extension "${package_path}" \
    --force \
    --extensions-dir "${extensions_dir}" \
    --user-data-dir "${user_data_dir}"
}
install_from_file "/tmp/cmux-vscode-extension-0.0.1.vsix"
rm -f /tmp/cmux-vscode-extension-0.0.1.vsix
download_dir="$(mktemp -d)"
cleanup() {
  rm -rf "${download_dir}"
}
trap cleanup EXIT
download_extension() {
  publisher="$1"
  name="$2"
  version="$3"
  destination="$4"
  tmpfile="${destination}.download"
  url="https://marketplace.visualstudio.com/_apis/public/gallery/publishers/${publisher}/vsextensions/${name}/${version}/vspackage"
  if ! curl -fSL --retry 6 --retry-all-errors --retry-delay 2 --connect-timeout 20 --max-time 600 -o "${tmpfile}" "${url}"; then
    echo "Failed to download ${publisher}.${name}@${version}" >&2
    rm -f "${tmpfile}"
    return 1
  fi
  if gzip -t "${tmpfile}" >/dev/null 2>&1; then
    gunzip -c "${tmpfile}" > "${destination}"
    rm -f "${tmpfile}"
  else
    mv "${tmpfile}" "${destination}"
  fi
}
while IFS='|' read -r publisher name version; do
  [ -z "${publisher}" ] && continue
  download_extension "${publisher}" "${name}" "${version}" "${download_dir}/${publisher}.${name}.vsix" &
done <<'EXTENSIONS'
anthropic|claude-code|2.0.27
openai|chatgpt|0.5.27
ms-vscode|vscode-typescript-next|5.9.20250531
ms-python|python|2025.6.1
ms-python|vscode-pylance|2025.8.100
ms-python|debugpy|2025.14.0
EXTENSIONS
wait
set -- "${download_dir}"/*.vsix
for vsix in "$@"; do
  if [ -f "${vsix}" ]; then
    install_from_file "${vsix}"
  fi
done
EOF

# Copy worker helper scripts
COPY apps/worker/scripts/collect-relevant-diff.sh /usr/local/bin/cmux-collect-relevant-diff.sh
COPY apps/worker/scripts/collect-crown-diff.sh /usr/local/bin/cmux-collect-crown-diff.sh
RUN chmod +x /usr/local/bin/cmux-collect-relevant-diff.sh \
  && chmod +x /usr/local/bin/cmux-collect-crown-diff.sh

# Copy vendored Rust binaries from rust-builder
COPY --from=rust-builder /usr/local/cargo/bin/envctl /usr/local/bin/envctl
COPY --from=rust-builder /usr/local/cargo/bin/envd /usr/local/bin/envd
COPY --from=rust-builder /usr/local/cargo/bin/cmux-proxy /usr/local/bin/cmux-proxy
COPY --from=rust-builder /usr/local/cargo/bin/cmux-xterm-server /usr/local/bin/cmux-xterm-server

# Configure envctl/envd runtime defaults
RUN chmod +x /usr/local/bin/envctl /usr/local/bin/envd /usr/local/bin/cmux-proxy /usr/local/bin/cmux-xterm-server && \
  envctl --version && \
  envctl install-hook bash && \
  echo '[ -f ~/.bashrc ] && . ~/.bashrc' > /root/.profile && \
  echo '[ -f ~/.bashrc ] && . ~/.bashrc' > /root/.bash_profile && \
  mkdir -p /run/user/0 && \
  chmod 700 /run/user/0 && \
  echo 'export XDG_RUNTIME_DIR=/run/user/0' >> /root/.bashrc

# Install tmux configuration for better mouse scrolling behavior
COPY configs/tmux.conf /etc/tmux.conf

# Create workspace and lifecycle directories
RUN mkdir -p /workspace /root/workspace /root/lifecycle

COPY prompt-wrapper.sh /usr/local/bin/prompt-wrapper
RUN chmod +x /usr/local/bin/prompt-wrapper

# Install cmux systemd units and helpers
RUN mkdir -p /usr/local/lib/cmux
COPY configs/systemd/cmux.target /usr/lib/systemd/system/cmux.target
COPY configs/systemd/cmux-openvscode.service /usr/lib/systemd/system/cmux-openvscode.service
COPY configs/systemd/cmux-worker.service /usr/lib/systemd/system/cmux-worker.service
COPY configs/systemd/cmux-proxy.service /usr/lib/systemd/system/cmux-proxy.service
COPY configs/systemd/cmux-dockerd.service /usr/lib/systemd/system/cmux-dockerd.service
COPY configs/systemd/cmux-devtools.service /usr/lib/systemd/system/cmux-devtools.service
COPY configs/systemd/cmux-xvfb.service /usr/lib/systemd/system/cmux-xvfb.service
COPY configs/systemd/cmux-tigervnc.service /usr/lib/systemd/system/cmux-tigervnc.service
COPY configs/systemd/cmux-vnc-proxy.service /usr/lib/systemd/system/cmux-vnc-proxy.service
COPY configs/systemd/cmux-cdp-proxy.service /usr/lib/systemd/system/cmux-cdp-proxy.service
COPY configs/systemd/cmux-xterm.service /usr/lib/systemd/system/cmux-xterm.service
COPY configs/systemd/cmux-memory-setup.service /usr/lib/systemd/system/cmux-memory-setup.service
COPY configs/systemd/bin/configure-openvscode /usr/local/lib/cmux/configure-openvscode
COPY configs/systemd/bin/cmux-start-chrome /usr/local/lib/cmux/cmux-start-chrome
COPY configs/systemd/bin/cmux-manage-dockerd /usr/local/lib/cmux/cmux-manage-dockerd
COPY configs/systemd/bin/cmux-stop-dockerd /usr/local/lib/cmux/cmux-stop-dockerd
COPY configs/systemd/bin/cmux-configure-memory /usr/local/sbin/cmux-configure-memory
COPY --from=builder /usr/local/lib/cmux/cmux-cdp-proxy /usr/local/lib/cmux/cmux-cdp-proxy
COPY --from=builder /usr/local/lib/cmux/cmux-vnc-proxy /usr/local/lib/cmux/cmux-vnc-proxy
RUN chmod +x /usr/local/lib/cmux/configure-openvscode /usr/local/lib/cmux/cmux-start-chrome /usr/local/lib/cmux/cmux-cdp-proxy /usr/local/lib/cmux/cmux-vnc-proxy && \
  chmod +x /usr/local/lib/cmux/cmux-manage-dockerd /usr/local/lib/cmux/cmux-stop-dockerd && \
  chmod +x /usr/local/sbin/cmux-configure-memory && \
  touch /usr/local/lib/cmux/dockerd.flag && \
  mkdir -p /var/log/cmux && \
  mkdir -p /etc/systemd/system/multi-user.target.wants && \
  mkdir -p /etc/systemd/system/cmux.target.wants && \
  mkdir -p /etc/systemd/system/swap.target.wants && \
  ln -sf /usr/lib/systemd/system/cmux.target /etc/systemd/system/multi-user.target.wants/cmux.target && \
  ln -sf /usr/lib/systemd/system/cmux-openvscode.service /etc/systemd/system/cmux.target.wants/cmux-openvscode.service && \
  ln -sf /usr/lib/systemd/system/cmux-worker.service /etc/systemd/system/cmux.target.wants/cmux-worker.service && \
  ln -sf /usr/lib/systemd/system/cmux-proxy.service /etc/systemd/system/cmux.target.wants/cmux-proxy.service && \
  ln -sf /usr/lib/systemd/system/cmux-dockerd.service /etc/systemd/system/cmux.target.wants/cmux-dockerd.service && \
  ln -sf /usr/lib/systemd/system/cmux-devtools.service /etc/systemd/system/cmux.target.wants/cmux-devtools.service && \
  ln -sf /usr/lib/systemd/system/cmux-tigervnc.service /etc/systemd/system/cmux.target.wants/cmux-tigervnc.service && \
  ln -sf /usr/lib/systemd/system/cmux-vnc-proxy.service /etc/systemd/system/cmux.target.wants/cmux-vnc-proxy.service && \
  ln -sf /usr/lib/systemd/system/cmux-cdp-proxy.service /etc/systemd/system/cmux.target.wants/cmux-cdp-proxy.service && \
  ln -sf /usr/lib/systemd/system/cmux-xterm.service /etc/systemd/system/cmux.target.wants/cmux-xterm.service && \
  ln -sf /usr/lib/systemd/system/cmux-memory-setup.service /etc/systemd/system/multi-user.target.wants/cmux-memory-setup.service && \
  ln -sf /usr/lib/systemd/system/cmux-memory-setup.service /etc/systemd/system/swap.target.wants/cmux-memory-setup.service && \
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
# 39375: Exec service (HTTP)
# 39376: VS Code Extension Socket Server
# 39377: Worker service
# 39378: OpenVSCode server
# 39379: cmux-proxy
# 39380: VNC websocket proxy (noVNC)
# 39381: Chrome DevTools (CDP)
# 39382: Chrome DevTools target
# 39383: cmux-xterm server
EXPOSE 39375 39376 39377 39378 39379 39380 39381 39382 39383

ENV container=docker
STOPSIGNAL SIGRTMIN+3
VOLUME [ "/sys/fs/cgroup" ]
WORKDIR /
ENTRYPOINT ["/usr/lib/systemd/systemd"]
CMD []

# Stage 3: DinD installer layer
FROM --platform=$BUILDPLATFORM ubuntu:24.04 AS dind-installer

ARG GITHUB_TOKEN
ARG DOCKER_VERSION
ARG DOCKER_CHANNEL
ARG DOCKER_COMPOSE_VERSION
ARG BUILDX_VERSION
ARG BUILDKIT_VERSION

# Install minimal dependencies for Docker installation
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
  --mount=type=cache,target=/var/lib/apt,sharing=locked \
  apt-get update && apt-get install -y --no-install-recommends \
  ca-certificates \
  curl \
  wget \
  jq

# Copy github-curl helper from builder
COPY --from=builder /usr/local/bin/github-curl /usr/local/bin/github-curl

# Install Docker
RUN --mount=type=secret,id=github_token,required=false <<-'EOF'
    set -eux; \
    arch="$(uname -m)"; \
    DOCKER_CHANNEL="${DOCKER_CHANNEL:-stable}"; \
    FALLBACK_DOCKER_VERSION="27.4.0"; \
    raw_version="${DOCKER_VERSION:-}"; \
    if [ -z "$raw_version" ]; then \
        raw_version="$(github-curl -fsSL https://api.github.com/repos/docker/docker/releases/latest | jq -r '.tag_name' | sed 's/^v//')"; \
    fi; \
    sanitize_version() { \
        local value="$1"; \
        value="${value#docker-}"; \
        value="${value#v}"; \
        printf '%s' "$value"; \
    }; \
    DOCKER_VERSION="$(sanitize_version "$raw_version")"; \
    case "$arch" in \
        x86_64) dockerArch='x86_64' ;; \
        aarch64) dockerArch='aarch64' ;; \
        *) echo >&2 "error: unsupported architecture ($arch)"; exit 1 ;; \
    esac; \
    download_docker() { \
        local version="$1"; \
        wget -O docker.tgz "https://download.docker.com/linux/static/${DOCKER_CHANNEL}/${dockerArch}/docker-${version}.tgz"; \
    }; \
    if ! download_docker "$DOCKER_VERSION"; then \
        if [ -z "${raw_version}" ]; then \
            DOCKER_VERSION="$FALLBACK_DOCKER_VERSION"; \
            download_docker "$DOCKER_VERSION"; \
        else \
            echo "Failed to download docker-${DOCKER_VERSION}.tgz" >&2; \
            exit 1; \
        fi; \
    fi; \
    tar --extract --file docker.tgz --strip-components 1 --directory /usr/local/bin/; \
    rm docker.tgz; \
    dockerd --version || echo "dockerd --version failed (ignored during build)"; \
    docker --version || echo "docker --version failed (ignored during build)"
EOF

# Install Docker Compose, Buildx, and BuildKit
RUN --mount=type=secret,id=github_token,required=false <<-'EOF'
    set -eux; \
    mkdir -p /usr/local/lib/docker/cli-plugins; \
    arch="$(uname -m)"; \
    case "$arch" in \
        x86_64) composeArch='x86_64'; buildxAsset='linux-amd64'; buildkitAsset='linux-amd64' ;; \
        aarch64) composeArch='aarch64'; buildxAsset='linux-arm64'; buildkitAsset='linux-arm64' ;; \
        *) echo >&2 "error: unsupported architecture ($arch)"; exit 1 ;; \
    esac; \
    FALLBACK_VERSION="2.24.7"; \
    raw_compose="${DOCKER_COMPOSE_VERSION:-$(github-curl -fsSL https://api.github.com/repos/docker/compose/releases/latest | jq -r '.tag_name' | sed 's/^v//')}"; \
    sanitize_version() { \
        local value="$1"; \
        value="${value#docker-}"; \
        value="${value#v}"; \
        printf '%s' "$value"; \
    }; \
    DOCKER_COMPOSE_VERSION="$(sanitize_version "$raw_compose")"; \
    github-curl -fsSL "https://github.com/docker/compose/releases/download/v${DOCKER_COMPOSE_VERSION}/docker-compose-linux-${composeArch}" \
        -o /usr/local/lib/docker/cli-plugins/docker-compose || { \
            if [ -z "${raw_compose}" ]; then \
                DOCKER_COMPOSE_VERSION="$FALLBACK_VERSION"; \
                github-curl -fsSL "https://github.com/docker/compose/releases/download/v${DOCKER_COMPOSE_VERSION}/docker-compose-linux-${composeArch}" \
                    -o /usr/local/lib/docker/cli-plugins/docker-compose; \
            else \
                exit 1; \
            fi; \
        }; \
    chmod +x /usr/local/lib/docker/cli-plugins/docker-compose; \
    BUILDX_FALLBACK="0.15.1"; \
    raw_buildx="${BUILDX_VERSION:-$(github-curl -fsSL https://api.github.com/repos/docker/buildx/releases/latest | jq -r '.tag_name' | sed 's/^v//')}"; \
    BUILDX_VERSION="$(sanitize_version "$raw_buildx")"; \
    github-curl -fsSL "https://github.com/docker/buildx/releases/download/v${BUILDX_VERSION}/buildx-v${BUILDX_VERSION}.${buildxAsset}" \
        -o /usr/local/lib/docker/cli-plugins/docker-buildx || { \
            if [ -z "${raw_buildx}" ]; then \
                BUILDX_VERSION="$BUILDX_FALLBACK"; \
                github-curl -fsSL "https://github.com/docker/buildx/releases/download/v${BUILDX_VERSION}/buildx-v${BUILDX_VERSION}.${buildxAsset}" \
                    -o /usr/local/lib/docker/cli-plugins/docker-buildx; \
            else \
                exit 1; \
            fi; \
        }; \
    chmod +x /usr/local/lib/docker/cli-plugins/docker-buildx; \
    BUILDKIT_FALLBACK="0.15.2"; \
    raw_buildkit="${BUILDKIT_VERSION:-$(github-curl -fsSL https://api.github.com/repos/moby/buildkit/releases/latest | jq -r '.tag_name' | sed 's/^v//')}"; \
    BUILDKIT_VERSION="$(sanitize_version "$raw_buildkit")"; \
    github-curl -fsSL "https://github.com/moby/buildkit/releases/download/v${BUILDKIT_VERSION}/buildkit-v${BUILDKIT_VERSION}.${buildkitAsset}.tar.gz" \
        -o /tmp/buildkit.tar.gz || { \
            if [ -z "${raw_buildkit}" ]; then \
                BUILDKIT_VERSION="$BUILDKIT_FALLBACK"; \
                github-curl -fsSL "https://github.com/moby/buildkit/releases/download/v${BUILDKIT_VERSION}/buildkit-v${BUILDKIT_VERSION}.${buildkitAsset}.tar.gz" \
                    -o /tmp/buildkit.tar.gz; \
            else \
                exit 1; \
            fi; \
        }; \
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

# Create supervisor config for dockerd
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

# Stage 4: Local (DinD) runtime with Docker available
FROM runtime-base AS runtime-local

# Switch to legacy iptables for Docker compatibility
RUN update-alternatives --set iptables /usr/sbin/iptables-legacy

# Copy Docker binaries and plugins from dind-installer
# Docker tarball includes: docker, dockerd, docker-init, docker-proxy, containerd, containerd-shim-runc-v2, runc, ctr
COPY --from=dind-installer /usr/local/bin/docker /usr/local/bin/docker
COPY --from=dind-installer /usr/local/bin/dockerd /usr/local/bin/dockerd
COPY --from=dind-installer /usr/local/bin/docker-init /usr/local/bin/docker-init
COPY --from=dind-installer /usr/local/bin/docker-proxy /usr/local/bin/docker-proxy
COPY --from=dind-installer /usr/local/bin/containerd /usr/local/bin/containerd
COPY --from=dind-installer /usr/local/bin/containerd-shim-runc-v2 /usr/local/bin/containerd-shim-runc-v2
COPY --from=dind-installer /usr/local/bin/runc /usr/local/bin/runc
COPY --from=dind-installer /usr/local/bin/ctr /usr/local/bin/ctr
COPY --from=dind-installer /usr/local/bin/buildctl /usr/local/bin/buildctl
COPY --from=dind-installer /usr/local/bin/buildkitd /usr/local/bin/buildkitd
COPY --from=dind-installer /usr/local/lib/docker/cli-plugins/ /usr/local/lib/docker/cli-plugins/
COPY --from=dind-installer /usr/local/bin/modprobe /usr/local/bin/modprobe
COPY --from=dind-installer /etc/supervisor/conf.d/dockerd.conf /etc/supervisor/conf.d/dockerd.conf

VOLUME /var/lib/docker

# Stage 5: Morph runtime without Docker
FROM runtime-base AS morph

# Final runtime image (default behaviour)
FROM runtime-local AS runtime-final
