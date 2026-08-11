#!/usr/bin/env bash

# Consume the lifecycle protocol that is owned by run-remote-demo.sh. FD7 is
# the caller's bootstrap writer and event_fd is read-only. The lifecycle
# supervisor owns the only writer after owner-started, so EOF or its explicit
# launcher-exited event is the process-death signal.
cmux_wait_for_remote_demo_ready() {
  local event_fd="$1"
  local transfer_timeout="$2"
  local startup_timeout="$3"
  local app_pid
  local event
  local read_status
  local transfer_deadline
  local startup_deadline
  local remaining
  CMUX_REMOTE_DEMO_APP_PID=""

  transfer_deadline=$((SECONDS + transfer_timeout))
  if IFS= read -r -t "$transfer_timeout" -u "$event_fd" event; then
    :
  else
    read_status=$?
    if (( read_status > 128 )); then
      return 20
    fi
    return 10
  fi
  case "$event" in
    owner-started) ;;
    launcher-exited\ [0-9]*)
      exec 7>&-
      return 10
      ;;
    failed\ [0-9]*)
      exec 7>&-
      return 10
      ;;
    *)
      exec 7>&-
      return 22
      ;;
  esac
  exec 7>&-

  while true; do
    remaining=$((transfer_deadline - SECONDS))
    (( remaining > 0 )) || return 20
    if IFS= read -r -t "$remaining" -u "$event_fd" event; then
      :
    else
      read_status=$?
      if (( read_status > 128 )); then
        return 20
      fi
      return 10
    fi
    case "$event" in
      daemon-starting) break ;;
      launcher-exited\ [0-9]*) return 10 ;;
      failed\ [0-9]*) return 10 ;;
      *) return 22 ;;
    esac
  done

  startup_deadline=$((SECONDS + startup_timeout))
  while true; do
    remaining=$((startup_deadline - SECONDS))
    (( remaining > 0 )) || return 21
    if IFS= read -r -t "$remaining" -u "$event_fd" event; then
      :
    else
      read_status=$?
      if (( read_status > 128 )); then
        return 21
      fi
      return 10
    fi
    case "$event" in
      app-started\ *)
        app_pid="${event#app-started }"
        [[ -z "$CMUX_REMOTE_DEMO_APP_PID" ]] || return 22
        [[ "$app_pid" =~ ^[1-9][0-9]*$ ]] || return 22
        CMUX_REMOTE_DEMO_APP_PID="$app_pid"
        ;;
      ready)
        [[ "$CMUX_REMOTE_DEMO_APP_PID" =~ ^[1-9][0-9]*$ ]] || return 22
        return 0
        ;;
      launcher-exited\ [0-9]*) return 10 ;;
      failed\ [0-9]*) return 10 ;;
      *) return 22 ;;
    esac
  done
}

cmux_wait_for_remote_demo_exit() {
  local event_fd="$1"
  local exit_timeout="$2"
  local event
  local launcher_status
  CMUX_REMOTE_DEMO_LAUNCHER_STATUS=""

  if ! IFS= read -r -t "$exit_timeout" -u "$event_fd" event; then
    return 1
  fi
  case "$event" in
    launcher-exited\ *)
      launcher_status="${event#launcher-exited }"
      [[ "$launcher_status" =~ ^[0-9]+$ ]] || return 22
      CMUX_REMOTE_DEMO_LAUNCHER_STATUS="$launcher_status"
      return 0
      ;;
    *) return 22 ;;
  esac
}
