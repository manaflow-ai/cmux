#!/usr/bin/env bash
# Builds the brain image and measures a cold container start to "plugin answers" (the host's
# readiness signal). Runs on a Freestyle VM with Docker (freestyle-run.sh --sync backend/chief-opencode).
set -euo pipefail
cd "$(dirname "$0")/.."
t0=$(date +%s%N)
docker build -q -f image/Dockerfile -t cmux-chief-opencode:bench . >/dev/null
echo "build_ms=$(( ($(date +%s%N) - t0) / 1000000 )) size=$(docker image inspect cmux-chief-opencode:bench --format '{{.Size}}')"
docker rm -f chief-bench >/dev/null 2>&1 || true
pw=$(cat /proc/sys/kernel/random/uuid)
cfg='{"plugins":[{"package":"/opt/cmux-chief/plugin","options":{"host":"http://127.0.0.1:9/cp","gateway":"http://127.0.0.1:9/v1"}}]}'
for i in 1 2 3; do
  docker rm -f chief-bench >/dev/null 2>&1 || true
  t0=$(date +%s%N)
  docker run -d --name chief-bench -p 14096:4096 -e OPENCODE_SERVER_PASSWORD="$pw" -e CMUX_CHIEF_TOKEN=bench -e OPENCODE_CONFIG_CONTENT="$cfg" cmux-chief-opencode:bench >/dev/null
  for _ in $(seq 1 600); do
    if curl -sf -u "opencode:$pw" -H 'content-type: application/json' -d '{"input":{"run":"ready"}}' http://127.0.0.1:14096/api/rpc/cmux-chief/status >/dev/null; then break; fi
    sleep 0.1
  done
  echo "cold_start_ms[$i]=$(( ($(date +%s%N) - t0) / 1000000 ))"
done
docker logs chief-bench 2>&1 | tail -3
docker rm -f chief-bench >/dev/null
