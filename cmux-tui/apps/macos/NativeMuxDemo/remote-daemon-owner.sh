#!/bin/sh

set -u

# Stdin is the local launcher's ownership lease. EOF means the launcher can no
# longer run its EXIT trap, so this process must reap the remote demo itself.

if [ "$#" -lt 6 ] || [ "$5" != "--" ]; then
  echo "Usage: remote-daemon-owner.sh <pid-file> <remote-root> <cmux-tui> <mux-socket> -- <daemon-command...>" >&2
  exit 2
fi

pid_file="$1"
remote_root="$2"
cmux_tui="$3"
mux_socket="$4"
shift 5

case "$remote_root" in
  /tmp/cmux-native-remote-demo.*) ;;
  *)
    echo "Refusing unsafe remote demo root: $remote_root" >&2
    exit 2
    ;;
esac
case "$pid_file" in
  "$remote_root"/*) ;;
  *)
    echo "Refusing PID file outside the remote demo root: $pid_file" >&2
    exit 2
    ;;
esac
case "$cmux_tui" in
  "$remote_root"/*) ;;
  *)
    echo "Refusing cmux-tui outside the remote demo root: $cmux_tui" >&2
    exit 2
    ;;
esac
case "$mux_socket" in
  "$remote_root"/*) ;;
  *)
    echo "Refusing mux socket outside the remote demo root: $mux_socket" >&2
    exit 2
    ;;
esac

daemon_pid=""
owner_reader_pid=""
cleanup_started=0

process_alive() {
  [ -n "$1" ] && /bin/kill -0 "$1" 2>/dev/null
}

daemon_matches() {
  command=$(/bin/ps -p "$daemon_pid" -o command= 2>/dev/null || true)
  case "$command" in
    "$cmux_tui daemon "*) return 0 ;;
    *) return 1 ;;
  esac
}

shutdown_session() {
  if [ -S "$mux_socket" ]; then
    "$cmux_tui" --socket "$mux_socket" \
      session current shutdown --force --json >/dev/null 2>&1 || true
  fi
}

wait_for_daemon_exit() {
  attempts="$1"
  while process_alive "$daemon_pid" && [ "$attempts" -gt 0 ]; do
    attempts=$((attempts - 1))
    /bin/sleep 0.1
  done
  ! process_alive "$daemon_pid"
}

host_pids() {
  /usr/bin/pgrep -f "^$cmux_tui __terminal-host --bootstrap-stdio$" 2>/dev/null || true
}

signal_hosts() {
  signal="$1"
  expected="$cmux_tui __terminal-host --bootstrap-stdio"
  for host_pid in $(host_pids); do
    command=$(/bin/ps -p "$host_pid" -o command= 2>/dev/null || true)
    if [ "$command" = "$expected" ]; then
      /bin/kill "-$signal" "$host_pid" 2>/dev/null || true
    fi
  done
}

wait_for_hosts_exit() {
  attempts="$1"
  while [ -n "$(host_pids)" ] && [ "$attempts" -gt 0 ]; do
    attempts=$((attempts - 1))
    /bin/sleep 0.1
  done
  [ -z "$(host_pids)" ]
}

cleanup() {
  status=$?
  if [ "$cleanup_started" = "1" ]; then
    exit "$status"
  fi
  cleanup_started=1
  trap - EXIT HUP INT TERM

  if process_alive "$owner_reader_pid"; then
    /bin/kill "$owner_reader_pid" 2>/dev/null || true
  fi
  if [ -n "$owner_reader_pid" ]; then
    wait "$owner_reader_pid" 2>/dev/null || true
    owner_reader_pid=""
  fi

  if process_alive "$daemon_pid"; then
    shutdown_session
    wait_for_daemon_exit 100 || true
  fi
  if process_alive "$daemon_pid"; then
    if daemon_matches; then
      /bin/kill -TERM "$daemon_pid" 2>/dev/null || true
      wait_for_daemon_exit 50 || true
    else
      echo "Refusing to signal unexpected remote daemon $daemon_pid." >&2
      status=1
    fi
  fi
  if process_alive "$daemon_pid"; then
    if daemon_matches; then
      /bin/kill -KILL "$daemon_pid" 2>/dev/null || true
      wait_for_daemon_exit 20 || true
    else
      status=1
    fi
  fi
  if [ -n "$daemon_pid" ]; then
    wait "$daemon_pid" 2>/dev/null || true
  fi

  signal_hosts TERM
  wait_for_hosts_exit 20 || true
  if [ -n "$(host_pids)" ]; then
    signal_hosts KILL
    wait_for_hosts_exit 20 || true
  fi

  if process_alive "$daemon_pid" || [ -n "$(host_pids)" ]; then
    echo "Remote demo owner could not reap every PTY process under $remote_root." >&2
    status=1
  else
    /bin/rm -rf -- "$remote_root"
  fi
  exit "$status"
}

trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

"$@" &
daemon_pid=$!
printf '%s\n' "$daemon_pid" >"$pid_file"

/bin/cat <&0 >/dev/null &
owner_reader_pid=$!

while process_alive "$daemon_pid" && process_alive "$owner_reader_pid"; do
  /bin/sleep 0.1
done

if ! process_alive "$owner_reader_pid"; then
  echo "Remote demo owner channel closed; shutting down its daemon." >&2
  exit 0
fi

echo "Remote demo daemon exited; releasing its owner channel." >&2
daemon_status=0
wait "$daemon_pid" || daemon_status=$?
daemon_pid=""
exit "$daemon_status"
