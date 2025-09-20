#!/usr/bin/env bash
set -euo pipefail

# Generated from Dockerfile by scripts/dockerfile_to_bash.py
# Safety:
# - By default, RUN blocks are NOT executed.
#   To execute them, set EXECUTE=1 ALLOW_DANGEROUS=1.
# - Filesystem operations write into DESTDIR, not host root.

EXECUTE=${EXECUTE:-0}
ALLOW_DANGEROUS=${ALLOW_DANGEROUS:-0}
BUILD_CONTEXT=/Users/lawrencechen/fun/cmux12
DESTDIR=${DESTDIR:-$(pwd)/_dockerfile_rootfs}
mkdir -p "$DESTDIR"
CURRENT_WORKDIR=/

do_safe() { echo "+ $*"; if [ "$EXECUTE" = "1" ]; then eval "$@"; fi; }

# syntax=docker/dockerfile:1.7-labs

# Stage 1: Build stage
# FROM ubuntu:24.04 AS builder
# (New stage begins)
CURRENT_WORKDIR=/

# ARG VERSION
do_safe export VERSION=""
# ARG CODE_RELEASE
do_safe export CODE_RELEASE=""
# ARG DOCKER_VERSION=28.3.2
do_safe export DOCKER_VERSION=28.3.2
# ARG DOCKER_CHANNEL=stable
do_safe export DOCKER_CHANNEL=stable

# Install build dependencies
if [ "$EXECUTE" = "1" ] && [ "$ALLOW_DANGEROUS" = "1" ]; then
  bash -euo pipefail <<'__CMUX_RUN__'
cd "${DESTDIR}${CURRENT_WORKDIR}"
apt-get update && apt-get install -y --no-install-recommends ca-certificates curl wget git python3 make g++ bash unzip gnupg && rm -rf /var/lib/apt/lists/*
__CMUX_RUN__
else
  cat <<'__CMUX_SHOW__'
apt-get update && apt-get install -y --no-install-recommends ca-certificates curl wget git python3 make g++ bash unzip gnupg && rm -rf /var/lib/apt/lists/*
__CMUX_SHOW__
fi


# Install Node.js 24.x
if [ "$EXECUTE" = "1" ] && [ "$ALLOW_DANGEROUS" = "1" ]; then
  bash -euo pipefail <<'__CMUX_RUN__'
cd "${DESTDIR}${CURRENT_WORKDIR}"
curl -fsSL https://deb.nodesource.com/setup_24.x | bash - && apt-get install -y nodejs && rm -rf /var/lib/apt/lists/* && npm install -g node-gyp && corepack enable && corepack prepare pnpm@10.14.0 --activate
__CMUX_RUN__
else
  cat <<'__CMUX_SHOW__'
curl -fsSL https://deb.nodesource.com/setup_24.x | bash - && apt-get install -y nodejs && rm -rf /var/lib/apt/lists/* && npm install -g node-gyp && corepack enable && corepack prepare pnpm@10.14.0 --activate
__CMUX_SHOW__
fi


# Install Bun
if [ "$EXECUTE" = "1" ] && [ "$ALLOW_DANGEROUS" = "1" ]; then
  bash -euo pipefail <<'__CMUX_RUN__'
cd "${DESTDIR}${CURRENT_WORKDIR}"
curl -fsSL https://bun.sh/install | bash && mv /root/.bun/bin/bun /usr/local/bin/ && ln -s /usr/local/bin/bun /usr/local/bin/bunx && bun --version && bunx --version
__CMUX_RUN__
else
  cat <<'__CMUX_SHOW__'
curl -fsSL https://bun.sh/install | bash && mv /root/.bun/bin/bun /usr/local/bin/ && ln -s /usr/local/bin/bun /usr/local/bin/bunx && bun --version && bunx --version
__CMUX_SHOW__
fi


# Install openvscode-server (with retries and IPv4 fallback)
if [ "$EXECUTE" = "1" ] && [ "$ALLOW_DANGEROUS" = "1" ]; then
  bash -euo pipefail <<'__CMUX_RUN__'
cd "${DESTDIR}${CURRENT_WORKDIR}"
if [ -z ${CODE_RELEASE} ]; then CODE_RELEASE=$(curl -sX GET https://api.github.com/repos/gitpod-io/openvscode-server/releases/latest | awk /tag_name/{print $4;exit} FS=["\"] | sed s|^openvscode-server-v||); fi && echo CODE_RELEASE=${CODE_RELEASE} && arch=$(dpkg --print-architecture) && if [ $arch = amd64 ]; then ARCH=x64; elif [ $arch = arm64 ]; then ARCH=arm64; fi && mkdir -p /app/openvscode-server && url=https://github.com/gitpod-io/openvscode-server/releases/download/openvscode-server-v${CODE_RELEASE}/openvscode-server-v${CODE_RELEASE}-linux-${ARCH}.tar.gz && echo Downloading: $url && ( curl -fSL --retry 6 --retry-all-errors --retry-delay 2 --connect-timeout 20 --max-time 600 -o /tmp/openvscode-server.tar.gz $url || curl -fSL4 --retry 6 --retry-all-errors --retry-delay 2 --connect-timeout 20 --max-time 600 -o /tmp/openvscode-server.tar.gz $url ) && tar xf /tmp/openvscode-server.tar.gz -C /app/openvscode-server/ --strip-components=1 && rm -rf /tmp/openvscode-server.tar.gz
__CMUX_RUN__
else
  cat <<'__CMUX_SHOW__'
if [ -z ${CODE_RELEASE} ]; then CODE_RELEASE=$(curl -sX GET https://api.github.com/repos/gitpod-io/openvscode-server/releases/latest | awk /tag_name/{print $4;exit} FS=["\"] | sed s|^openvscode-server-v||); fi && echo CODE_RELEASE=${CODE_RELEASE} && arch=$(dpkg --print-architecture) && if [ $arch = amd64 ]; then ARCH=x64; elif [ $arch = arm64 ]; then ARCH=arm64; fi && mkdir -p /app/openvscode-server && url=https://github.com/gitpod-io/openvscode-server/releases/download/openvscode-server-v${CODE_RELEASE}/openvscode-server-v${CODE_RELEASE}-linux-${ARCH}.tar.gz && echo Downloading: $url && ( curl -fSL --retry 6 --retry-all-errors --retry-delay 2 --connect-timeout 20 --max-time 600 -o /tmp/openvscode-server.tar.gz $url || curl -fSL4 --retry 6 --retry-all-errors --retry-delay 2 --connect-timeout 20 --max-time 600 -o /tmp/openvscode-server.tar.gz $url ) && tar xf /tmp/openvscode-server.tar.gz -C /app/openvscode-server/ --strip-components=1 && rm -rf /tmp/openvscode-server.tar.gz
__CMUX_SHOW__
fi


# Copy package files for monorepo dependency installation
# WORKDIR /cmux
CURRENT_WORKDIR="/cmux"
do_safe mkdir -p "$DESTDIR$CURRENT_WORKDIR"
do_safe cd "$DESTDIR$CURRENT_WORKDIR"
# COPY  package.json bun.lock .npmrc ./
# COPY -> copying into './' under DESTDIR
do_safe mkdir -p "$DESTDIR./" 2>/dev/null || true
do_safe cp -R "$BUILD_CONTEXT/package.json" "$DESTDIR./"
do_safe cp -R "$BUILD_CONTEXT/bun.lock" "$DESTDIR./"
do_safe cp -R "$BUILD_CONTEXT/.npmrc" "$DESTDIR./"
# COPY --parents apps/*/package.json packages/*/package.json scripts/package.json ./
# COPY -> copying into './' under DESTDIR
do_safe mkdir -p "$DESTDIR./" 2>/dev/null || true
do_safe cp -R "$BUILD_CONTEXT/apps/*/package.json" "$DESTDIR./"
do_safe cp -R "$BUILD_CONTEXT/packages/*/package.json" "$DESTDIR./"
do_safe cp -R "$BUILD_CONTEXT/scripts/package.json" "$DESTDIR./"

if [ "$EXECUTE" = "1" ] && [ "$ALLOW_DANGEROUS" = "1" ]; then
  bash -euo pipefail <<'__CMUX_RUN__'
cd "${DESTDIR}${CURRENT_WORKDIR}"
bun install --frozen-lockfile --production
__CMUX_RUN__
else
  cat <<'__CMUX_SHOW__'
bun install --frozen-lockfile --production
__CMUX_SHOW__
fi


if [ "$EXECUTE" = "1" ] && [ "$ALLOW_DANGEROUS" = "1" ]; then
  bash -euo pipefail <<'__CMUX_RUN__'
cd "${DESTDIR}${CURRENT_WORKDIR}"
mkdir -p /builtins && echo {"name":"builtins","type":"module","version":"1.0.0"} > /builtins/package.json
__CMUX_RUN__
else
  cat <<'__CMUX_SHOW__'
mkdir -p /builtins && echo {"name":"builtins","type":"module","version":"1.0.0"} > /builtins/package.json
__CMUX_SHOW__
fi

# WORKDIR /builtins
CURRENT_WORKDIR="/builtins"
do_safe mkdir -p "$DESTDIR$CURRENT_WORKDIR"
do_safe cd "$DESTDIR$CURRENT_WORKDIR"

# Copy source files needed for build
# WORKDIR /cmux
CURRENT_WORKDIR="/cmux"
do_safe mkdir -p "$DESTDIR$CURRENT_WORKDIR"
do_safe cd "$DESTDIR$CURRENT_WORKDIR"
# Copy shared package source and config
# COPY  packages/shared/src ./packages/shared/src
# COPY -> copying into './packages/shared/src' under DESTDIR
do_safe mkdir -p "$DESTDIR./packages/shared/src" 2>/dev/null || true
do_safe cp -R "$BUILD_CONTEXT/packages/shared/src" "$DESTDIR./packages/shared/src"
# COPY  packages/shared/tsconfig.json ./packages/shared/
# COPY -> copying into './packages/shared/' under DESTDIR
do_safe mkdir -p "$DESTDIR./packages/shared/" 2>/dev/null || true
do_safe cp -R "$BUILD_CONTEXT/packages/shared/tsconfig.json" "$DESTDIR./packages/shared/"

# Copy convex package (needed by shared)
# COPY  packages/convex ./packages/convex/
# COPY -> copying into './packages/convex/' under DESTDIR
do_safe mkdir -p "$DESTDIR./packages/convex/" 2>/dev/null || true
do_safe cp -R "$BUILD_CONTEXT/packages/convex" "$DESTDIR./packages/convex/"

# Copy worker source and scripts
# COPY  apps/worker/src ./apps/worker/src
# COPY -> copying into './apps/worker/src' under DESTDIR
do_safe mkdir -p "$DESTDIR./apps/worker/src" 2>/dev/null || true
do_safe cp -R "$BUILD_CONTEXT/apps/worker/src" "$DESTDIR./apps/worker/src"
# COPY  apps/worker/scripts ./apps/worker/scripts
# COPY -> copying into './apps/worker/scripts' under DESTDIR
do_safe mkdir -p "$DESTDIR./apps/worker/scripts" 2>/dev/null || true
do_safe cp -R "$BUILD_CONTEXT/apps/worker/scripts" "$DESTDIR./apps/worker/scripts"
# COPY  apps/worker/tsconfig.json ./apps/worker/
# COPY -> copying into './apps/worker/' under DESTDIR
do_safe mkdir -p "$DESTDIR./apps/worker/" 2>/dev/null || true
do_safe cp -R "$BUILD_CONTEXT/apps/worker/tsconfig.json" "$DESTDIR./apps/worker/"
# COPY  apps/worker/wait-for-docker.sh ./apps/worker/
# COPY -> copying into './apps/worker/' under DESTDIR
do_safe mkdir -p "$DESTDIR./apps/worker/" 2>/dev/null || true
do_safe cp -R "$BUILD_CONTEXT/apps/worker/wait-for-docker.sh" "$DESTDIR./apps/worker/"

# Copy VS Code extension source
# COPY  packages/vscode-extension/src ./packages/vscode-extension/src
# COPY -> copying into './packages/vscode-extension/src' under DESTDIR
do_safe mkdir -p "$DESTDIR./packages/vscode-extension/src" 2>/dev/null || true
do_safe cp -R "$BUILD_CONTEXT/packages/vscode-extension/src" "$DESTDIR./packages/vscode-extension/src"
# COPY  packages/vscode-extension/tsconfig.json ./packages/vscode-extension/
# COPY -> copying into './packages/vscode-extension/' under DESTDIR
do_safe mkdir -p "$DESTDIR./packages/vscode-extension/" 2>/dev/null || true
do_safe cp -R "$BUILD_CONTEXT/packages/vscode-extension/tsconfig.json" "$DESTDIR./packages/vscode-extension/"
# COPY  packages/vscode-extension/.vscodeignore ./packages/vscode-extension/
# COPY -> copying into './packages/vscode-extension/' under DESTDIR
do_safe mkdir -p "$DESTDIR./packages/vscode-extension/" 2>/dev/null || true
do_safe cp -R "$BUILD_CONTEXT/packages/vscode-extension/.vscodeignore" "$DESTDIR./packages/vscode-extension/"
# COPY  packages/vscode-extension/LICENSE.md ./packages/vscode-extension/
# COPY -> copying into './packages/vscode-extension/' under DESTDIR
do_safe mkdir -p "$DESTDIR./packages/vscode-extension/" 2>/dev/null || true
do_safe cp -R "$BUILD_CONTEXT/packages/vscode-extension/LICENSE.md" "$DESTDIR./packages/vscode-extension/"

# Build worker with bundling, using the installed node_modules
if [ "$EXECUTE" = "1" ] && [ "$ALLOW_DANGEROUS" = "1" ]; then
  bash -euo pipefail <<'__CMUX_RUN__'
cd "${DESTDIR}${CURRENT_WORKDIR}"
cd /cmux && bun build ./apps/worker/src/index.ts --target node --outdir ./apps/worker/build --external @cmux/convex --external node:* && echo Built worker && cp -r ./apps/worker/build /builtins/build && cp ./apps/worker/wait-for-docker.sh /usr/local/bin/ && chmod +x /usr/local/bin/wait-for-docker.sh
__CMUX_RUN__
else
  cat <<'__CMUX_SHOW__'
cd /cmux && bun build ./apps/worker/src/index.ts --target node --outdir ./apps/worker/build --external @cmux/convex --external node:* && echo Built worker && cp -r ./apps/worker/build /builtins/build && cp ./apps/worker/wait-for-docker.sh /usr/local/bin/ && chmod +x /usr/local/bin/wait-for-docker.sh
__CMUX_SHOW__
fi


# Verify bun is still working in builder
if [ "$EXECUTE" = "1" ] && [ "$ALLOW_DANGEROUS" = "1" ]; then
  bash -euo pipefail <<'__CMUX_RUN__'
cd "${DESTDIR}${CURRENT_WORKDIR}"
bun --version && bunx --version
__CMUX_RUN__
else
  cat <<'__CMUX_SHOW__'
bun --version && bunx --version
__CMUX_SHOW__
fi


# Build vscode extension
# WORKDIR /cmux/packages/vscode-extension
CURRENT_WORKDIR="/cmux/packages/vscode-extension"
do_safe mkdir -p "$DESTDIR$CURRENT_WORKDIR"
do_safe cd "$DESTDIR$CURRENT_WORKDIR"
if [ "$EXECUTE" = "1" ] && [ "$ALLOW_DANGEROUS" = "1" ]; then
  bash -euo pipefail <<'__CMUX_RUN__'
cd "${DESTDIR}${CURRENT_WORKDIR}"
bun run package && cp cmux-vscode-extension-0.0.1.vsix /tmp/cmux-vscode-extension-0.0.1.vsix
__CMUX_RUN__
else
  cat <<'__CMUX_SHOW__'
bun run package && cp cmux-vscode-extension-0.0.1.vsix /tmp/cmux-vscode-extension-0.0.1.vsix
__CMUX_SHOW__
fi


# Install VS Code extensions
if [ "$EXECUTE" = "1" ] && [ "$ALLOW_DANGEROUS" = "1" ]; then
  bash -euo pipefail <<'__CMUX_RUN__'
cd "${DESTDIR}${CURRENT_WORKDIR}"
/app/openvscode-server/bin/openvscode-server --install-extension /tmp/cmux-vscode-extension-0.0.1.vsix && rm /tmp/cmux-vscode-extension-0.0.1.vsix
__CMUX_RUN__
else
  cat <<'__CMUX_SHOW__'
/app/openvscode-server/bin/openvscode-server --install-extension /tmp/cmux-vscode-extension-0.0.1.vsix && rm /tmp/cmux-vscode-extension-0.0.1.vsix
__CMUX_SHOW__
fi


# Stage 2: Runtime stage
# FROM ubuntu:24.04 AS runtime
# (New stage begins)
CURRENT_WORKDIR=/

# ARG DOCKER_VERSION=28.3.2
do_safe export DOCKER_VERSION=28.3.2
# ARG DOCKER_CHANNEL=stable
do_safe export DOCKER_CHANNEL=stable

# Install runtime dependencies only
if [ "$EXECUTE" = "1" ] && [ "$ALLOW_DANGEROUS" = "1" ]; then
  bash -euo pipefail <<'__CMUX_RUN__'
cd "${DESTDIR}${CURRENT_WORKDIR}"
apt-get update && apt-get install -y --no-install-recommends ca-certificates curl wget git python3 bash nano net-tools lsof sudo supervisor iptables openssl pigz xz-utils tmux ripgrep jq && rm -rf /var/lib/apt/lists/*
__CMUX_RUN__
else
  cat <<'__CMUX_SHOW__'
apt-get update && apt-get install -y --no-install-recommends ca-certificates curl wget git python3 bash nano net-tools lsof sudo supervisor iptables openssl pigz xz-utils tmux ripgrep jq && rm -rf /var/lib/apt/lists/*
__CMUX_SHOW__
fi


# Install GitHub CLI
if [ "$EXECUTE" = "1" ] && [ "$ALLOW_DANGEROUS" = "1" ]; then
  bash -euo pipefail <<'__CMUX_RUN__'
cd "${DESTDIR}${CURRENT_WORKDIR}"
curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg | dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg && chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg && echo deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main | tee /etc/apt/sources.list.d/github-cli.list > /dev/null && apt-get update && apt-get install -y gh && rm -rf /var/lib/apt/lists/*
__CMUX_RUN__
else
  cat <<'__CMUX_SHOW__'
curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg | dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg && chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg && echo deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main | tee /etc/apt/sources.list.d/github-cli.list > /dev/null && apt-get update && apt-get install -y gh && rm -rf /var/lib/apt/lists/*
__CMUX_SHOW__
fi


# Install Node.js 24.x (runtime) and enable pnpm via corepack
if [ "$EXECUTE" = "1" ] && [ "$ALLOW_DANGEROUS" = "1" ]; then
  bash -euo pipefail <<'__CMUX_RUN__'
cd "${DESTDIR}${CURRENT_WORKDIR}"
curl -fsSL https://deb.nodesource.com/setup_24.x | bash - && apt-get install -y nodejs && rm -rf /var/lib/apt/lists/* && corepack enable && corepack prepare pnpm@10.14.0 --activate
__CMUX_RUN__
else
  cat <<'__CMUX_SHOW__'
curl -fsSL https://deb.nodesource.com/setup_24.x | bash - && apt-get install -y nodejs && rm -rf /var/lib/apt/lists/* && corepack enable && corepack prepare pnpm@10.14.0 --activate
__CMUX_SHOW__
fi


# Copy Bun from builder
# COPY --from=builder /usr/local/bin/bun /usr/local/bin/bun
# Skipping stage copy on host (requires image layer)
# COPY --from=builder /usr/local/bin/bunx /usr/local/bin/bunx
# Skipping stage copy on host (requires image layer)

# Verify bun works in runtime
if [ "$EXECUTE" = "1" ] && [ "$ALLOW_DANGEROUS" = "1" ]; then
  bash -euo pipefail <<'__CMUX_RUN__'
cd "${DESTDIR}${CURRENT_WORKDIR}"
bun --version && bunx --version
__CMUX_RUN__
else
  cat <<'__CMUX_SHOW__'
bun --version && bunx --version
__CMUX_SHOW__
fi


if [ "$EXECUTE" = "1" ] && [ "$ALLOW_DANGEROUS" = "1" ]; then
  bash -euo pipefail <<'__CMUX_RUN__'
cd "${DESTDIR}${CURRENT_WORKDIR}"
bun add -g @openai/codex@0.36.0 @anthropic-ai/claude-code@1.0.83 @google/gemini-cli@0.1.21 opencode-ai@0.6.4 codebuff @devcontainers/cli @sourcegraph/amp
__CMUX_RUN__
else
  cat <<'__CMUX_SHOW__'
bun add -g @openai/codex@0.36.0 @anthropic-ai/claude-code@1.0.83 @google/gemini-cli@0.1.21 opencode-ai@0.6.4 codebuff @devcontainers/cli @sourcegraph/amp
__CMUX_SHOW__
fi


# Install cursor cli
if [ "$EXECUTE" = "1" ] && [ "$ALLOW_DANGEROUS" = "1" ]; then
  bash -euo pipefail <<'__CMUX_RUN__'
cd "${DESTDIR}${CURRENT_WORKDIR}"
curl https://cursor.com/install -fsS | bash
__CMUX_RUN__
else
  cat <<'__CMUX_SHOW__'
curl https://cursor.com/install -fsS | bash
__CMUX_SHOW__
fi

if [ "$EXECUTE" = "1" ] && [ "$ALLOW_DANGEROUS" = "1" ]; then
  bash -euo pipefail <<'__CMUX_RUN__'
cd "${DESTDIR}${CURRENT_WORKDIR}"
/root/.local/bin/cursor-agent --version
__CMUX_RUN__
else
  cat <<'__CMUX_SHOW__'
/root/.local/bin/cursor-agent --version
__CMUX_SHOW__
fi


# Set iptables-legacy (required for Docker in Docker on Ubuntu 22.04+)
if [ "$EXECUTE" = "1" ] && [ "$ALLOW_DANGEROUS" = "1" ]; then
  bash -euo pipefail <<'__CMUX_RUN__'
cd "${DESTDIR}${CURRENT_WORKDIR}"
update-alternatives --set iptables /usr/sbin/iptables-legacy
__CMUX_RUN__
else
  cat <<'__CMUX_SHOW__'
update-alternatives --set iptables /usr/sbin/iptables-legacy
__CMUX_SHOW__
fi


# Install Docker
if [ "$EXECUTE" = "1" ] && [ "$ALLOW_DANGEROUS" = "1" ]; then
  bash -euo pipefail <<'__CMUX_RUN__'
cd "${DESTDIR}${CURRENT_WORKDIR}"
    set -eux; \
    arch="$(uname -m)"; \
    case "$arch" in \
        x86_64) dockerArch='x86_64' ;; \
        aarch64) dockerArch='aarch64' ;; \
        *) echo >&2 "error: unsupported architecture ($arch)"; exit 1 ;; \
    esac; \
    wget -O docker.tgz "https://download.docker.com/linux/static/${DOCKER_CHANNEL}/${dockerArch}/docker-${DOCKER_VERSION}.tgz"; \
    tar --extract --file docker.tgz --strip-components 1 --directory /usr/local/bin/; \
    rm docker.tgz; \
    dockerd --version; \
    docker --version
__CMUX_RUN__
else
  cat <<'__CMUX_SHOW__'
    set -eux; \
    arch="$(uname -m)"; \
    case "$arch" in \
        x86_64) dockerArch='x86_64' ;; \
        aarch64) dockerArch='aarch64' ;; \
        *) echo >&2 "error: unsupported architecture ($arch)"; exit 1 ;; \
    esac; \
    wget -O docker.tgz "https://download.docker.com/linux/static/${DOCKER_CHANNEL}/${dockerArch}/docker-${DOCKER_VERSION}.tgz"; \
    tar --extract --file docker.tgz --strip-components 1 --directory /usr/local/bin/; \
    rm docker.tgz; \
    dockerd --version; \
    docker --version
__CMUX_SHOW__
fi


# Install Docker Compose and Buildx plugins
if [ "$EXECUTE" = "1" ] && [ "$ALLOW_DANGEROUS" = "1" ]; then
  bash -euo pipefail <<'__CMUX_RUN__'
cd "${DESTDIR}${CURRENT_WORKDIR}"
    set -eux; \
    mkdir -p /usr/local/lib/docker/cli-plugins; \
    arch="$(uname -m)"; \
    # Install Docker Compose
    curl -SL "https://github.com/docker/compose/releases/download/v2.32.2/docker-compose-linux-${arch}" \
        -o /usr/local/lib/docker/cli-plugins/docker-compose; \
    chmod +x /usr/local/lib/docker/cli-plugins/docker-compose; \
    # Install Docker Buildx
    curl -SL "https://github.com/docker/buildx/releases/download/v0.18.0/buildx-v0.18.0.linux-${arch}" \
        -o /usr/local/lib/docker/cli-plugins/docker-buildx; \
    chmod +x /usr/local/lib/docker/cli-plugins/docker-buildx; \
    echo "Docker plugins installed successfully"
__CMUX_RUN__
else
  cat <<'__CMUX_SHOW__'
    set -eux; \
    mkdir -p /usr/local/lib/docker/cli-plugins; \
    arch="$(uname -m)"; \
    # Install Docker Compose
    curl -SL "https://github.com/docker/compose/releases/download/v2.32.2/docker-compose-linux-${arch}" \
        -o /usr/local/lib/docker/cli-plugins/docker-compose; \
    chmod +x /usr/local/lib/docker/cli-plugins/docker-compose; \
    # Install Docker Buildx
    curl -SL "https://github.com/docker/buildx/releases/download/v0.18.0/buildx-v0.18.0.linux-${arch}" \
        -o /usr/local/lib/docker/cli-plugins/docker-buildx; \
    chmod +x /usr/local/lib/docker/cli-plugins/docker-buildx; \
    echo "Docker plugins installed successfully"
__CMUX_SHOW__
fi


# Skip docker-init installation - ubuntu-dind doesn't have it

# Set Bun path
# ENV PATH="/usr/local/bin:$PATH"
do_safe export PATH=/usr/local/bin:$PATH

# Copy only the built artifacts and runtime dependencies from builder
# COPY --from=builder /app/openvscode-server /app/openvscode-server
# Skipping stage copy on host (requires image layer)
# COPY --from=builder /root/.openvscode-server /root/.openvscode-server
# Skipping stage copy on host (requires image layer)
# COPY --from=builder /builtins /builtins
# Skipping stage copy on host (requires image layer)
# COPY --from=builder /usr/local/bin/wait-for-docker.sh /usr/local/bin/wait-for-docker.sh
# Skipping stage copy on host (requires image layer)
# COPY --from=builder /cmux/apps/worker/scripts/collect-relevant-diff.sh /usr/local/bin/cmux-collect-relevant-diff.sh
# Skipping stage copy on host (requires image layer)
if [ "$EXECUTE" = "1" ] && [ "$ALLOW_DANGEROUS" = "1" ]; then
  bash -euo pipefail <<'__CMUX_RUN__'
cd "${DESTDIR}${CURRENT_WORKDIR}"
chmod +x /usr/local/bin/cmux-collect-relevant-diff.sh
__CMUX_RUN__
else
  cat <<'__CMUX_SHOW__'
chmod +x /usr/local/bin/cmux-collect-relevant-diff.sh
__CMUX_SHOW__
fi


# Install envctl/envd into runtime
if [ "$EXECUTE" = "1" ] && [ "$ALLOW_DANGEROUS" = "1" ]; then
  bash -euo pipefail <<'__CMUX_RUN__'
cd "${DESTDIR}${CURRENT_WORKDIR}"
CMUX_ENV_VERSION=0.0.7 curl https://raw.githubusercontent.com/lawrencecchen/cmux-env/refs/heads/main/scripts/install.sh | bash && envctl --version && envctl install-hook bash && echo [ -f ~/.bashrc ] && . ~/.bashrc > /root/.profile && echo [ -f ~/.bashrc ] && . ~/.bashrc > /root/.bash_profile && echo [ -f ~/.bashrc ] && . ~/.bashrc >> /app/openvscode-server/out/vs/workbench/contrib/terminal/common/scripts/shellIntegration-bash.sh
__CMUX_RUN__
else
  cat <<'__CMUX_SHOW__'
CMUX_ENV_VERSION=0.0.7 curl https://raw.githubusercontent.com/lawrencecchen/cmux-env/refs/heads/main/scripts/install.sh | bash && envctl --version && envctl install-hook bash && echo [ -f ~/.bashrc ] && . ~/.bashrc > /root/.profile && echo [ -f ~/.bashrc ] && . ~/.bashrc > /root/.bash_profile && echo [ -f ~/.bashrc ] && . ~/.bashrc >> /app/openvscode-server/out/vs/workbench/contrib/terminal/common/scripts/shellIntegration-bash.sh
__CMUX_SHOW__
fi


# Install tmux configuration for better mouse scrolling behavior
# COPY  configs/tmux.conf /etc/tmux.conf
# COPY -> copying into '/etc/tmux.conf' under DESTDIR
do_safe mkdir -p "$DESTDIR/etc/tmux.conf" 2>/dev/null || true
do_safe cp -R "$BUILD_CONTEXT/configs/tmux.conf" "$DESTDIR/etc/tmux.conf"

if [ "$EXECUTE" = "1" ] && [ "$ALLOW_DANGEROUS" = "1" ]; then
  bash -euo pipefail <<'__CMUX_RUN__'
cd "${DESTDIR}${CURRENT_WORKDIR}"
claude_vsix=$(rg --files /root/.bun/install/cache/@anthropic-ai 2>/dev/null | rg claude-code\.vsix$ | head -1) && if [ -n $claude_vsix ]; then echo Found claude-code.vsix at: $claude_vsix && /app/openvscode-server/bin/openvscode-server --install-extension $claude_vsix; else echo Warning: claude-code.vsix not found in Bun cache && exit 1; fi
__CMUX_RUN__
else
  cat <<'__CMUX_SHOW__'
claude_vsix=$(rg --files /root/.bun/install/cache/@anthropic-ai 2>/dev/null | rg claude-code\.vsix$ | head -1) && if [ -n $claude_vsix ]; then echo Found claude-code.vsix at: $claude_vsix && /app/openvscode-server/bin/openvscode-server --install-extension $claude_vsix; else echo Warning: claude-code.vsix not found in Bun cache && exit 1; fi
__CMUX_SHOW__
fi


# Create modprobe script (required for DinD)
if [ "$EXECUTE" = "1" ] && [ "$ALLOW_DANGEROUS" = "1" ]; then
  bash -euo pipefail <<'__CMUX_RUN__'
cd "${DESTDIR}${CURRENT_WORKDIR}"
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
__CMUX_RUN__
else
  cat <<'__CMUX_SHOW__'
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
__CMUX_SHOW__
fi


# Create workspace and lifecycle directories
if [ "$EXECUTE" = "1" ] && [ "$ALLOW_DANGEROUS" = "1" ]; then
  bash -euo pipefail <<'__CMUX_RUN__'
cd "${DESTDIR}${CURRENT_WORKDIR}"
mkdir -p /workspace /root/workspace /root/lifecycle
__CMUX_RUN__
else
  cat <<'__CMUX_SHOW__'
mkdir -p /workspace /root/workspace /root/lifecycle
__CMUX_SHOW__
fi


# VOLUME /var/lib/docker

# Create supervisor config for dockerd
# Based on https://github.com/cruizba/ubuntu-dind
if [ "$EXECUTE" = "1" ] && [ "$ALLOW_DANGEROUS" = "1" ]; then
  bash -euo pipefail <<'__CMUX_RUN__'
cd "${DESTDIR}${CURRENT_WORKDIR}"
mkdir -p /etc/supervisor/conf.d
cat > /etc/supervisor/conf.d/dockerd.conf << 'CONFIG'
[program:dockerd]
command=/usr/local/bin/dockerd
autostart=true
autorestart=true
stderr_logfile=/var/log/dockerd.err.log
stdout_logfile=/var/log/dockerd.out.log
CONFIG
__CMUX_RUN__
else
  cat <<'__CMUX_SHOW__'
mkdir -p /etc/supervisor/conf.d
cat > /etc/supervisor/conf.d/dockerd.conf << 'CONFIG'
[program:dockerd]
command=/usr/local/bin/dockerd
autostart=true
autorestart=true
stderr_logfile=/var/log/dockerd.err.log
stdout_logfile=/var/log/dockerd.out.log
CONFIG
__CMUX_SHOW__
fi


# Copy startup script and prompt wrapper
# COPY  startup.sh /startup.sh
# COPY -> copying into '/startup.sh' under DESTDIR
do_safe mkdir -p "$DESTDIR/startup.sh" 2>/dev/null || true
do_safe cp -R "$BUILD_CONTEXT/startup.sh" "$DESTDIR/startup.sh"
# COPY  prompt-wrapper.sh /usr/local/bin/prompt-wrapper
# COPY -> copying into '/usr/local/bin/prompt-wrapper' under DESTDIR
do_safe mkdir -p "$DESTDIR/usr/local/bin/prompt-wrapper" 2>/dev/null || true
do_safe cp -R "$BUILD_CONTEXT/prompt-wrapper.sh" "$DESTDIR/usr/local/bin/prompt-wrapper"
if [ "$EXECUTE" = "1" ] && [ "$ALLOW_DANGEROUS" = "1" ]; then
  bash -euo pipefail <<'__CMUX_RUN__'
cd "${DESTDIR}${CURRENT_WORKDIR}"
chmod +x /startup.sh /usr/local/bin/prompt-wrapper
__CMUX_RUN__
else
  cat <<'__CMUX_SHOW__'
chmod +x /startup.sh /usr/local/bin/prompt-wrapper
__CMUX_SHOW__
fi


# Create VS Code user settings
if [ "$EXECUTE" = "1" ] && [ "$ALLOW_DANGEROUS" = "1" ]; then
  bash -euo pipefail <<'__CMUX_RUN__'
cd "${DESTDIR}${CURRENT_WORKDIR}"
mkdir -p /root/.openvscode-server/data/User && echo {"workbench.startupEditor": "none", "terminal.integrated.macOptionClickForcesSelection": true, "terminal.integrated.shell.linux": "bash", "terminal.integrated.shellArgs.linux": ["-l"]} > /root/.openvscode-server/data/User/settings.json && mkdir -p /root/.openvscode-server/data/User/profiles/default-profile && echo {"workbench.startupEditor": "none", "terminal.integrated.macOptionClickForcesSelection": true, "terminal.integrated.shell.linux": "bash", "terminal.integrated.shellArgs.linux": ["-l"]} > /root/.openvscode-server/data/User/profiles/default-profile/settings.json && mkdir -p /root/.openvscode-server/data/Machine && echo {"workbench.startupEditor": "none", "terminal.integrated.macOptionClickForcesSelection": true, "terminal.integrated.shell.linux": "bash", "terminal.integrated.shellArgs.linux": ["-l"]} > /root/.openvscode-server/data/Machine/settings.json
__CMUX_RUN__
else
  cat <<'__CMUX_SHOW__'
mkdir -p /root/.openvscode-server/data/User && echo {"workbench.startupEditor": "none", "terminal.integrated.macOptionClickForcesSelection": true, "terminal.integrated.shell.linux": "bash", "terminal.integrated.shellArgs.linux": ["-l"]} > /root/.openvscode-server/data/User/settings.json && mkdir -p /root/.openvscode-server/data/User/profiles/default-profile && echo {"workbench.startupEditor": "none", "terminal.integrated.macOptionClickForcesSelection": true, "terminal.integrated.shell.linux": "bash", "terminal.integrated.shellArgs.linux": ["-l"]} > /root/.openvscode-server/data/User/profiles/default-profile/settings.json && mkdir -p /root/.openvscode-server/data/Machine && echo {"workbench.startupEditor": "none", "terminal.integrated.macOptionClickForcesSelection": true, "terminal.integrated.shell.linux": "bash", "terminal.integrated.shellArgs.linux": ["-l"]} > /root/.openvscode-server/data/Machine/settings.json
__CMUX_SHOW__
fi


# Ports
# 39376: VS Code Extension Socket Server
# 39377: Worker service
# 39378: OpenVSCode server
# EXPOSE 39376 39377 39378

# WORKDIR /
CURRENT_WORKDIR="/"
do_safe mkdir -p "$DESTDIR$CURRENT_WORKDIR"
do_safe cd "$DESTDIR$CURRENT_WORKDIR"

# ENTRYPOINT ["/startup.sh"]
# CMD []
