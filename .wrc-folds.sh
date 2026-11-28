#!/bin/bash
set -uo pipefail
cd webviews
bun install --frozen-lockfile > /tmp/wrc-install.log 2>&1 || { tail -30 /tmp/wrc-install.log; exit 3; }
bun test "$@" 2>&1
