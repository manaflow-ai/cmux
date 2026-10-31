# The Cloud Chief brain O: one opencode v2 server per Chief with the cmux-chief plugin, run as a
# Cloudflare Container bound to OpencodeBrainDO (backend/apps/api/src/chief-brain-opencode/brain-do.ts).
# Build context: backend/chief-opencode. The host passes OPENCODE_SERVER_PASSWORD, CMUX_CHIEF_TOKEN and
# OPENCODE_CONFIG_CONTENT (plugin options: host CP endpoint, model gateway) at start; nothing secret is baked in.
#
# wrangler.jsonc (per env), when the deployment turns O on:
#   "containers": [{ "class_name": "OpencodeBrainDO", "image": "../../chief-opencode/image/Dockerfile",
#                    "image_build_context": "../../chief-opencode", "max_instances": 50, "instance_type": "standard-1" }]
#   a durable_objects binding OPENCODE_BRAIN_DO -> OpencodeBrainDO, a new_sqlite_classes migration tag,
#   vars CHIEF_OPENCODE_ENABLED "1" and CHIEF_OPENCODE_CONTAINER "1".
FROM node:24-slim@sha256:55fb5f5a527ea2c5c4a95f963e48ef90aa38c7b346054fdc8ee9957a2b55d205 AS cli
ARG OPENCODE_VERSION=2.0.29
RUN npm install --prefix /opt/oc2 --no-fund --no-audit "@opencode/cli-linux-x64@${OPENCODE_VERSION}"

# The CLI is one self-contained binary: no Node in the running image. The plugin's `effect` and
# `@opencode/plugin` imports resolve to the binary's own runtime, so the plugin needs no node_modules.
FROM debian:bookworm-slim@sha256:7ff6ba31527b9e336162fa061746c366c4b2032f4d2cff2078bea43f78efe3f8
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates && rm -rf /var/lib/apt/lists/*
COPY --from=cli /opt/oc2/node_modules/@opencode/cli-linux-x64/bin/opencode /usr/local/bin/opencode
RUN opencode --version
COPY plugin /opt/cmux-chief/plugin
WORKDIR /chief
ENV OPENCODE_DISABLE_PROJECT_CONFIG=1
EXPOSE 4096
CMD ["opencode", "serve", "--hostname", "0.0.0.0", "--port", "4096"]
