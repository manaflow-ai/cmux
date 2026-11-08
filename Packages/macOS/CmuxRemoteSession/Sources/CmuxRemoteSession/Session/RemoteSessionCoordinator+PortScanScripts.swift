// Remote shell programs emit positive port rows plus completion markers for
// exactly the scan scopes that produced authoritative negative evidence.
extension RemoteSessionCoordinator {
    /// Builds the TTY-scoped remote listening-port scan program.
    static func remotePortScanScript(
        ttyNames: [String],
        excluding ports: Set<Int>,
        protecting protectedPortsByTTY: [String: Set<Int>]
    ) -> String {
        let ttySet = ttyNames.joined(separator: " ")
        let ttyCSV = ttyNames.joined(separator: ",")
        let excludedPorts = ports.sorted().map(String.init).joined(separator: " ")
        let protectedTTYPorts = protectedPortsByTTY.keys.sorted().flatMap { ttyName in
            (protectedPortsByTTY[ttyName] ?? []).sorted().map { "\(ttyName):\($0)" }
        }.joined(separator: " ")

        return """
        set -eu
        cmux_tracked_ttys=" \(ttySet) "
        cmux_tty_csv='\(ttyCSV)'
        cmux_excluded_ports=" \(excludedPorts) "
        cmux_protected_tty_ports=" \(protectedTTYPorts) "
        cmux_scan_complete=0
        cmux_tmpdir="$(mktemp -d 2>/dev/null || mktemp -d -t cmux-ports 2>/dev/null || true)"
        cmux_global_incomplete=""
        cmux_incomplete_ttys=""
        cmux_tab="$(printf '\\t')"
        if [ -n "$cmux_tmpdir" ]; then
          cmux_global_incomplete="$cmux_tmpdir/global-incomplete"
          cmux_incomplete_ttys="$cmux_tmpdir/incomplete-ttys"
          : > "$cmux_incomplete_ttys"
          trap 'rm -rf "$cmux_tmpdir"' EXIT INT TERM
        fi

        cmux_mark_globally_incomplete() {
          [ -n "$cmux_global_incomplete" ] && : > "$cmux_global_incomplete"
          return 0
        }

        cmux_mark_tty_incomplete() {
          cmux_incomplete_tty="$1"
          case "$cmux_tracked_ttys" in
            *" $cmux_incomplete_tty "*) ;;
            *) return 0 ;;
          esac
          [ -n "$cmux_incomplete_ttys" ] && printf '%s\\n' "$cmux_incomplete_tty" >> "$cmux_incomplete_ttys"
          return 0
        }

        cmux_mark_port_owners_incomplete() {
          cmux_ambiguous_port="$1"
          for cmux_owner_tty in $cmux_tracked_ttys; do
            case "$cmux_protected_tty_ports" in
              *" $cmux_owner_tty:$cmux_ambiguous_port "*) cmux_mark_tty_incomplete "$cmux_owner_tty" ;;
            esac
          done
          return 0
        }

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
          if [ -n "$cmux_tmpdir" ]; then
            cmux_ss_stderr="$cmux_tmpdir/ss.stderr"
            cmux_ss_output="$(ss -ltnpH 2>"$cmux_ss_stderr")" || cmux_ss_status=$?
            [ ! -s "$cmux_ss_stderr" ] || cmux_mark_globally_incomplete
          else
            cmux_ss_output="$(ss -ltnpH 2>/dev/null)" || cmux_ss_status=$?
            cmux_mark_globally_incomplete
          fi
          [ "$cmux_ss_status" -eq 0 ] || cmux_mark_globally_incomplete
          case "$cmux_ss_output" in
            "")
              if [ "$cmux_ss_status" -eq 0 ]; then
                cmux_used_ss=1
                cmux_scan_complete=1
              fi
              ;;
            *pid=*)
              cmux_used_ss=1
              [ "$cmux_ss_status" -ne 0 ] || cmux_scan_complete=1
              printf '%s\\n' "$cmux_ss_output" | while IFS= read -r cmux_line; do
                [ -n "$cmux_line" ] || continue
                cmux_port="$(printf '%s\\n' "$cmux_line" | awk '{print $4}' | sed -E 's/.*:([0-9]+)$/\\1/' | awk '/^[0-9]+$/ { print $1; exit }')"
                if [ -z "$cmux_port" ]; then cmux_mark_globally_incomplete; continue; fi
                cmux_pid_tokens="$(printf '%s\\n' "$cmux_line" | awk '
                  {
                    line = $0
                    while (match(line, /pid=[^,)]*/)) {
                      token = substr(line, RSTART, RLENGTH)
                      if (token ~ /^pid=[0-9]+$/) {
                        print substr(token, 5)
                      } else {
                        print "__cmux_invalid_pid__"
                      }
                      line = substr(line, RSTART + RLENGTH)
                    }
                  }
                ')"
                if [ -z "$cmux_pid_tokens" ]; then
                  cmux_mark_port_owners_incomplete "$cmux_port"
                  continue
                fi
                for cmux_pid in $cmux_pid_tokens; do
                  if [ "$cmux_pid" = "__cmux_invalid_pid__" ]; then
                    cmux_mark_port_owners_incomplete "$cmux_port"
                    continue
                  fi
                  cmux_tty_path="$(readlink "/proc/$cmux_pid/fd/0" 2>/dev/null || true)"
                  if [ -z "$cmux_tty_path" ]; then cmux_mark_port_owners_incomplete "$cmux_port"; continue; fi
                  cmux_tty="${cmux_tty_path##*/}"
                  if [ -z "$cmux_tty" ]; then cmux_mark_port_owners_incomplete "$cmux_port"; continue; fi
                  cmux_emit_port "$cmux_tty" "$cmux_port"
                done
              done
              ;;
          esac
        fi

        if [ "$cmux_used_ss" -eq 0 ] && [ -n "$cmux_tmpdir" ] && command -v lsof >/dev/null 2>&1 && [ -n "$cmux_tty_csv" ]; then
          rm -f "$cmux_global_incomplete"
          : > "$cmux_incomplete_ttys"
          cmux_scan_complete=0
          cmux_pid_tty_map="$cmux_tmpdir/pid_tty"
          cmux_ps_stderr="$cmux_tmpdir/ps.stderr"
          cmux_ps_status=0
          cmux_ps_output="$(ps -t "$cmux_tty_csv" -o pid=,tty= 2>"$cmux_ps_stderr")" || cmux_ps_status=$?
          if [ -s "$cmux_ps_stderr" ]; then exit 0; fi
          # BSD ps exits 1 when a valid selector matches no processes.
          if [ "$cmux_ps_status" -ne 0 ] && { [ "$cmux_ps_status" -ne 1 ] || [ -n "$cmux_ps_output" ]; }; then
            exit 0
          fi
          printf '%s\\n' "$cmux_ps_output" | awk -v globally_incomplete="$cmux_global_incomplete" '
            NF == 2 && $1 ~ /^[0-9]+$/ {
              tty = $2
              sub(/^.*\\//, "", tty)
              if (tty != "") {
                print $1 "\\t" tty
              } else {
                print "1" > globally_incomplete
                close(globally_incomplete)
              }
              next
            }
            NF > 0 {
              print "1" > globally_incomplete
              close(globally_incomplete)
            }
          ' > "$cmux_pid_tty_map"
          if [ ! -s "$cmux_pid_tty_map" ]; then cmux_scan_complete=1; fi
          cmux_pid_csv="$(awk '{print $1}' "$cmux_pid_tty_map" | paste -sd, -)"
          if [ -n "$cmux_pid_csv" ]; then
            cmux_lsof_stderr="$cmux_tmpdir/lsof.stderr"
            cmux_lsof_status=0
            cmux_lsof_output="$(lsof -nP -a -p "$cmux_pid_csv" -iTCP -sTCP:LISTEN -Fpn 2>"$cmux_lsof_stderr")" || cmux_lsof_status=$?
            printf '%s\\n' "$cmux_lsof_output" | awk \
              -v map="$cmux_pid_tty_map" \
              -v globally_incomplete="$cmux_global_incomplete" \
              -v incomplete_ttys="$cmux_incomplete_ttys" '
              function mark_global() {
                print "1" > globally_incomplete
                close(globally_incomplete)
              }
              function mark_tty(value) {
                if (value != "") {
                  print value >> incomplete_ttys
                  close(incomplete_ttys)
                } else {
                  mark_global()
                }
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
                if (tty == "") mark_global()
                next
              }
              $0 ~ /^p/ {
                tty = ""
                mark_global()
                next
              }
              $0 ~ /^n/ && tty != "" {
                name = substr($0, 2)
                sub(/->.*/, "", name)
                sub(/^.*:/, "", name)
                if (name ~ /^[0-9]+$/) {
                  print tty "\\t" name
                } else {
                  mark_tty(tty)
                }
                next
              }
              $0 ~ /^n/ { mark_global(); next }
              $0 ~ /^f.+$/ { next }
              NF > 0 { mark_tty(tty) }
            ' | while IFS="$cmux_tab" read -r cmux_tty cmux_port; do
              [ -n "$cmux_tty" ] || continue
              [ -n "$cmux_port" ] || continue
              cmux_emit_port "$cmux_tty" "$cmux_port"
            done
            if [ ! -s "$cmux_lsof_stderr" ] && [ "$cmux_lsof_status" -eq 0 ]; then
              cmux_scan_complete=1
            elif [ ! -s "$cmux_lsof_stderr" ] && [ "$cmux_lsof_status" -eq 1 ]; then
              cmux_scan_complete=1
              while IFS="$cmux_tab" read -r cmux_pid cmux_tty; do
                kill -0 "$cmux_pid" 2>/dev/null || cmux_mark_tty_incomplete "$cmux_tty"
              done < "$cmux_pid_tty_map"
            else
              cmux_mark_globally_incomplete
            fi
          fi
        fi
        if [ "$cmux_scan_complete" -eq 1 ] && [ -n "$cmux_global_incomplete" ] && [ ! -e "$cmux_global_incomplete" ]; then
          for cmux_complete_tty in $cmux_tracked_ttys; do
            grep -F -x -e "$cmux_complete_tty" "$cmux_incomplete_ttys" >/dev/null 2>&1 && continue
            printf '%s\\t%s\\n' '\(remoteTTYPortScanCompleteMarker)' "$cmux_complete_tty"
          done
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
        cmux_scan_output=""
        cmux_scan_status=127
        cmux_scanner=""
        cmux_tmpdir="$(mktemp -d 2>/dev/null || mktemp -d -t cmux-ports 2>/dev/null || true)"
        cmux_scan_stderr=""
        if [ -n "$cmux_tmpdir" ]; then
          cmux_scan_stderr="$cmux_tmpdir/scanner.stderr"
          trap 'rm -rf "$cmux_tmpdir"' EXIT INT TERM
        fi

        cmux_emit_port() {
          cmux_port="$1"
          case "$cmux_excluded_ports" in
            *" $cmux_port "*) return 0 ;;
          esac
          [ "$cmux_port" -ge 1024 ] && [ "$cmux_port" -le 65535 ] || return 0
          printf '%s\\n' "$cmux_port"
        }

        cmux_run_scanner() {
          cmux_scan_status=0
          if [ -n "$cmux_scan_stderr" ]; then
            cmux_scan_output="$("$@" 2>"$cmux_scan_stderr")" || cmux_scan_status=$?
          else
            cmux_scan_output="$("$@" 2>/dev/null)" || cmux_scan_status=$?
          fi
        }

        if command -v ss >/dev/null 2>&1; then
          cmux_scanner=ss
          cmux_run_scanner ss -ltnH
        elif command -v netstat >/dev/null 2>&1; then
          cmux_scanner=netstat
          cmux_run_scanner netstat -lnt
        elif command -v lsof >/dev/null 2>&1; then
          cmux_scanner=lsof
          cmux_run_scanner lsof -nP -iTCP -sTCP:LISTEN
        fi

        cmux_parsed_output=""
        case "$cmux_scanner" in
          ss)
            cmux_parsed_output="$(printf '%s\\n' "$cmux_scan_output" | awk '
              NF == 0 { next }
              {
                name = $4
                sub(/^.*:/, "", name)
                if (name ~ /^[0-9]+$/) print name
                else print "__cmux_incomplete__"
              }
            ')"
            ;;
          netstat)
            cmux_parsed_output="$(printf '%s\\n' "$cmux_scan_output" | awk '
              NF == 0 || $1 == "Proto" || /^Active Internet/ { next }
              {
                name = $4
                sub(/^.*:/, "", name)
                if (name ~ /^[0-9]+$/) print name
                else print "__cmux_incomplete__"
              }
            ')"
            ;;
          lsof)
            cmux_parsed_output="$(printf '%s\\n' "$cmux_scan_output" | awk '
              NF == 0 || $1 == "COMMAND" { next }
              {
                name = $9
                sub(/->.*/, "", name)
                sub(/^.*:/, "", name)
                if (name ~ /^[0-9]+$/) print name
                else print "__cmux_incomplete__"
              }
            ')"
            ;;
        esac

        cmux_parse_complete=1
        case "$cmux_parsed_output" in
          *__cmux_incomplete__*) cmux_parse_complete=0 ;;
        esac
        printf '%s\\n' "$cmux_parsed_output" | while IFS= read -r cmux_port; do
          [ -n "$cmux_port" ] || continue
          [ "$cmux_port" != "__cmux_incomplete__" ] || continue
          cmux_emit_port "$cmux_port"
        done

        cmux_command_complete=0
        if [ -n "$cmux_scan_stderr" ] && [ ! -s "$cmux_scan_stderr" ]; then
          if [ "$cmux_scan_status" -eq 0 ]; then
            cmux_command_complete=1
          elif [ "$cmux_scanner" = lsof ] && [ "$cmux_scan_status" -eq 1 ] && [ -z "$cmux_scan_output" ]; then
            cmux_command_complete=1
          fi
        fi
        if [ "$cmux_command_complete" -eq 1 ] && [ "$cmux_parse_complete" -eq 1 ]; then
          printf '%s\\n' '\(remotePortScanCompleteMarker)'
        fi
        exit 0
        """
    }
}
