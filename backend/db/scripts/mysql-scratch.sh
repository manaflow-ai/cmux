#!/usr/bin/env bash
# Local scratch MySQL 8.4 for the test-mysql suite (plans/cmux-next/state-placement.md 4.4).
#   scripts/mysql-scratch.sh up    -> starts the container, applies migrations, prints export MYSQL_URL=...
#   scripts/mysql-scratch.sh down  -> removes the container
set -euo pipefail
NAME="${CMUX_MYSQL_SCRATCH_NAME:-cmux-next-mysql-scratch}"
PORT="${CMUX_MYSQL_SCRATCH_PORT:-33061}"
URL="mysql://root:scratch@127.0.0.1:${PORT}/cmux_next"
case "${1:-up}" in
  up)
    if ! docker inspect "$NAME" >/dev/null 2>&1; then
      docker run -d --name "$NAME" -p "127.0.0.1:${PORT}:3306" -e MYSQL_ROOT_PASSWORD=scratch -e MYSQL_DATABASE=cmux_next mysql:8.4 \
        --character-set-server=utf8mb4 --collation-server=utf8mb4_0900_ai_ci >/dev/null
    fi
    # The image restarts mysqld once after initialization; wait for the final server on the TCP port.
    for _ in $(seq 1 120); do
      docker exec "$NAME" mysql -h127.0.0.1 -uroot -pscratch -e "SELECT 1" cmux_next >/dev/null 2>&1 && break
      sleep 1
    done
    cd "$(dirname "$0")/.."
    MYSQL_URL="$URL" bun migrate-mysql.ts --url-env MYSQL_URL >&2
    echo "export MYSQL_URL=$URL"
    ;;
  down) docker rm -f "$NAME" >/dev/null ;;
  *) echo "usage: $0 up|down" >&2; exit 2 ;;
esac
