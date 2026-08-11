#!/usr/bin/env bash

# Consume the lifecycle protocol that is owned by run-remote-demo.sh. Binary
# transfer has its own budget; daemon startup begins at the first event.
cmux_wait_for_remote_demo_ready() {
  local event_fd="$1"
  local launcher_pid="$2"
  local transfer_timeout="$3"
  local startup_timeout="$4"
  local event
  local startup_deadline
  local remaining
  CMUX_REMOTE_DEMO_APP_PID=""

  if ! IFS= read -r -t "$transfer_timeout" -u "$event_fd" event; then
    kill -0 "$launcher_pid" 2>/dev/null || return 10
    return 20
  fi
  case "$event" in
    daemon-starting) ;;
    failed\ [0-9]*) return 10 ;;
    *) return 22 ;;
  esac

  startup_deadline=$((SECONDS + startup_timeout))
  while true; do
    remaining=$((startup_deadline - SECONDS))
    (( remaining > 0 )) || return 21
    if ! IFS= read -r -t "$remaining" -u "$event_fd" event; then
      kill -0 "$launcher_pid" 2>/dev/null || return 10
      return 21
    fi
    case "$event" in
      app-started\ [1-9][0-9]*)
        CMUX_REMOTE_DEMO_APP_PID="${event#app-started }"
        ;;
      ready)
        [[ "$CMUX_REMOTE_DEMO_APP_PID" =~ ^[1-9][0-9]*$ ]] || return 22
        return 0
        ;;
      failed\ [0-9]*) return 10 ;;
      *) return 22 ;;
    esac
  done
}
