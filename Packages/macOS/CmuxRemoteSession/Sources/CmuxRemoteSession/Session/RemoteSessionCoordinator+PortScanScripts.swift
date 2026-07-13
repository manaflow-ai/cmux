// Remote shell programs emit positive port rows plus a completion marker only
// when every scanner stage produced authoritative output.
extension RemoteSessionCoordinator {
    /// Builds the TTY-scoped remote listening-port scan program.
    static func remotePortScanScript(ttyNames: [String], excluding ports: Set<Int>) -> String {
        let ttySet = ttyNames.joined(separator: " ")
        let ttyCSV = ttyNames.joined(separator: ",")
        let excludedPorts = ports.sorted().map(String.init).joined(separator: " ")

        return """
        set -eu
        cmux_tracked_ttys=" \(ttySet) "
        cmux_tty_csv='\(ttyCSV)'
        cmux_excluded_ports=" \(excludedPorts) "
        cmux_scan_complete=0
        cmux_tmpdir="$(mktemp -d 2>/dev/null || mktemp -d -t cmux-ports)" || exit 0
        cmux_scan_incomplete="$cmux_tmpdir/incomplete"
        trap 'rm -rf "$cmux_tmpdir"' EXIT INT TERM

        cmux_emit_port() {
          cmux_tty="$1"
          cmux_port="$2"
          case "$cmux_tracked_ttys" in
            *" $cmux_tty "*) ;;
            *) return 0 ;;
          esac
          case "$cmux_excluded_ports" in
            *" $cmux_port "*) return 0 ;;
          esac
          [ "$cmux_port" -ge 1024 ] && [ "$cmux_port" -le 65535 ] || return 0
          printf '%s\\t%s\\n' "$cmux_tty" "$cmux_port"
        }

        cmux_used_ss=0
        if [ -d /proc ] && command -v ss >/dev/null 2>&1; then
          cmux_ss_status=0
          cmux_ss_output="$(ss -ltnpH 2>/dev/null)" || cmux_ss_status=$?
          case "$cmux_ss_status:$cmux_ss_output" in
            0:) cmux_used_ss=1; cmux_scan_complete=1 ;;
            0:*pid=*)
              cmux_used_ss=1
              cmux_scan_complete=1
              printf '%s\\n' "$cmux_ss_output" | while IFS= read -r cmux_line; do
                [ -n "$cmux_line" ] || continue
                cmux_port="$(printf '%s\\n' "$cmux_line" | awk '{print $4}' | sed -E 's/.*:([0-9]+)$/\\1/' | awk '/^[0-9]+$/ { print $1; exit }')"
                if [ -z "$cmux_port" ]; then : > "$cmux_scan_incomplete"; continue; fi
                cmux_pids="$(printf '%s\\n' "$cmux_line" | awk '
                  {
                    line = $0
                    while (match(line, /pid=[0-9]+/)) {
                      print substr(line, RSTART + 4, RLENGTH - 4)
                      line = substr(line, RSTART + RLENGTH)
                    }
                  }
                ')"
                if [ -z "$cmux_pids" ]; then : > "$cmux_scan_incomplete"; continue; fi
                for cmux_pid in $cmux_pids; do
                  cmux_tty_path="$(readlink "/proc/$cmux_pid/fd/0" 2>/dev/null || true)"
                  if [ -z "$cmux_tty_path" ]; then : > "$cmux_scan_incomplete"; continue; fi
                  cmux_tty="${cmux_tty_path##*/}"
                  if [ -z "$cmux_tty" ]; then : > "$cmux_scan_incomplete"; continue; fi
                  cmux_emit_port "$cmux_tty" "$cmux_port"
                done
              done
              ;;
          esac
        fi

        if [ "$cmux_used_ss" -eq 0 ] && command -v lsof >/dev/null 2>&1 && [ -n "$cmux_tty_csv" ]; then
          cmux_pid_tty_map="$cmux_tmpdir/pid_tty"
          cmux_ps_stderr="$cmux_tmpdir/ps.stderr"
          cmux_ps_status=0
          cmux_ps_output="$(ps -t "$cmux_tty_csv" -o pid=,tty= 2>"$cmux_ps_stderr")" || cmux_ps_status=$?
          [ "$cmux_ps_status" -eq 0 ] && [ ! -s "$cmux_ps_stderr" ] || exit 0
          printf '%s\\n' "$cmux_ps_output" | awk -v incomplete="$cmux_scan_incomplete" '
            NF == 2 && $1 ~ /^[0-9]+$/ {
              tty = $2
              sub(/^.*\\//, "", tty)
              if (tty != "") {
                print $1 "\\t" tty
              } else {
                print "1" > incomplete
                close(incomplete)
              }
              next
            }
            NF > 0 {
              print "1" > incomplete
              close(incomplete)
            }
          ' > "$cmux_pid_tty_map"
          if [ ! -s "$cmux_pid_tty_map" ]; then cmux_scan_complete=1; fi
          cmux_pid_csv="$(awk '{print $1}' "$cmux_pid_tty_map" | paste -sd, -)"
          if [ -n "$cmux_pid_csv" ]; then
            cmux_lsof_stderr="$cmux_tmpdir/lsof.stderr"
            cmux_lsof_status=0
            cmux_lsof_output="$(lsof -nP -a -p "$cmux_pid_csv" -iTCP -sTCP:LISTEN -Fpn 2>"$cmux_lsof_stderr")" || cmux_lsof_status=$?
            printf '%s\\n' "$cmux_lsof_output" | awk -v map="$cmux_pid_tty_map" -v incomplete="$cmux_scan_incomplete" '
              function mark_incomplete() {
                print "1" > incomplete
                close(incomplete)
              }
              BEGIN {
                while ((getline < map) > 0) {
                  pid_to_tty[$1] = $2
                }
                close(map)
              }
              $0 ~ /^p[0-9]+$/ {
                pid = substr($0, 2)
                tty = pid_to_tty[pid]
                if (tty == "") mark_incomplete()
                next
              }
              $0 ~ /^p/ {
                tty = ""
                mark_incomplete()
                next
              }
              $0 ~ /^n/ && tty != "" {
                name = substr($0, 2)
                sub(/->.*/, "", name)
                sub(/^.*:/, "", name)
                if (name ~ /^[0-9]+$/) {
                  print tty "\\t" name
                } else {
                  mark_incomplete()
                }
                next
              }
              $0 ~ /^n/ { mark_incomplete(); next }
              $0 ~ /^f.+$/ { next }
              NF > 0 { mark_incomplete() }
            ' | while IFS=$'\\t' read -r cmux_tty cmux_port; do
              [ -n "$cmux_tty" ] || continue
              [ -n "$cmux_port" ] || continue
              cmux_emit_port "$cmux_tty" "$cmux_port"
            done
            if [ ! -s "$cmux_lsof_stderr" ] && [ "$cmux_lsof_status" -eq 0 ]; then
              cmux_scan_complete=1
            elif [ ! -s "$cmux_lsof_stderr" ] && [ "$cmux_lsof_status" -eq 1 ] && [ -z "$cmux_lsof_output" ]; then
              cmux_scan_complete=1
              for cmux_pid in $(awk '{print $1}' "$cmux_pid_tty_map"); do
                kill -0 "$cmux_pid" 2>/dev/null || cmux_scan_complete=0
              done
            fi
          fi
        fi
        if [ "$cmux_scan_complete" -eq 1 ] && [ ! -e "$cmux_scan_incomplete" ]; then
          printf '%s\\n' '\(remotePortScanCompleteMarker)'
        fi
        exit 0
        """
    }

    /// Builds the host-wide fallback listening-port scan program.
    static func remoteAllPortsScanScript(excluding ports: Set<Int>) -> String {
        let excludedPorts = ports.sorted().map(String.init).joined(separator: " ")

        return """
        set -eu
        cmux_excluded_ports=" \(excludedPorts) "

        cmux_emit_port() {
          cmux_port="$1"
          case "$cmux_excluded_ports" in
            *" $cmux_port "*) return 0 ;;
          esac
          [ "$cmux_port" -ge 1024 ] && [ "$cmux_port" -le 65535 ] || return 0
          printf '%s\\n' "$cmux_port"
        }

        if command -v ss >/dev/null 2>&1; then
          ss -ltnH 2>/dev/null | awk '{print $4}' | sed -E 's/.*:([0-9]+)$/\\1/' | awk '/^[0-9]+$/ {print $1}' | while IFS= read -r cmux_port; do
            [ -n "$cmux_port" ] || continue
            cmux_emit_port "$cmux_port"
          done
        elif command -v netstat >/dev/null 2>&1; then
          netstat -lnt 2>/dev/null | awk 'NR > 2 {print $4}' | sed -E 's/.*:([0-9]+)$/\\1/' | awk '/^[0-9]+$/ {print $1}' | while IFS= read -r cmux_port; do
            [ -n "$cmux_port" ] || continue
            cmux_emit_port "$cmux_port"
          done
        elif command -v lsof >/dev/null 2>&1; then
          lsof -nP -iTCP -sTCP:LISTEN 2>/dev/null | awk 'NR > 1 {print $9}' | sed -E 's/.*:([0-9]+)$/\\1/' | awk '/^[0-9]+$/ {print $1}' | while IFS= read -r cmux_port; do
            [ -n "$cmux_port" ] || continue
            cmux_emit_port "$cmux_port"
          done
        fi
        """
    }
}
