public import Foundation

// Remote-side relay provisioning script builders. Static because they
// compose pure script text from raw inputs independent of a session instance
// (the CmuxCore SSH-option-normalization precedent); the script text is
// wire/process behavior pinned by tests — do not alter.
extension RemoteSessionCoordinator {
    /// Script that removes the relay metadata files for `relayPort` and the
    /// `socket_addr` pointer when it still points at that relay.
    public static func remoteRelayMetadataCleanupScript(relayPort: Int) -> String {
        """
        relay_socket='127.0.0.1:\(relayPort)'
        socket_addr_file="$HOME/.cmux/socket_addr"
        if [ -r "$socket_addr_file" ] && [ "$(tr -d '\\r\\n' < "$socket_addr_file")" = "$relay_socket" ]; then
          rm -f "$socket_addr_file"
        fi
        rm -f "$HOME/.cmux/relay/\(relayPort).auth" "$HOME/.cmux/relay/\(relayPort).daemon_path" "$HOME/.cmux/relay/\(relayPort).slot" "$HOME/.cmux/relay/\(relayPort).tty"
        """
    }

    /// Script that kills a stale sshd listener (and its persistent
    /// cmuxd-remote children for `persistentDaemonSlot`) still bound to
    /// `relayPort`, or `nil` when the inputs cannot be matched safely.
    public static func remoteStaleRelayListenerCleanupScript(
        relayPort: Int,
        persistentDaemonSlot: String?
    ) -> String? {
        guard relayPort > 0, relayPort <= 65535 else { return nil }
        guard let persistentDaemonSlot = normalizedPersistentDaemonSlotForRemoteCleanup(persistentDaemonSlot) else {
            return nil
        }

        return """
        cmux_stale_relay_listener_cleanup=1
        cmux_relay_port='\(relayPort)'
        cmux_persistent_slot=\(persistentDaemonSlot.shellSingleQuoted)
        cmux_listener_pids=''
        if command -v lsof >/dev/null 2>&1; then
          cmux_listener_pids="$(lsof -nP -iTCP:"$cmux_relay_port" -sTCP:LISTEN -Fpn 2>/dev/null | awk -v port="$cmux_relay_port" '
            /^p/ { pid = substr($0, 2); next }
            /^n/ {
              name = substr($0, 2)
              if (pid ~ /^[0-9]+$/ && name ~ ("(^|[^0-9])127[.]0[.]0[.]1:" port "$")) {
                seen[pid] = 1
              }
            }
            END {
              for (pid in seen) print pid
            }
          ')"
        fi
        [ -n "$cmux_listener_pids" ] || exit 0
        cmux_ps_output="$(ps -axo pid=,ppid=,command= 2>/dev/null || true)"
        for cmux_listener_pid in $cmux_listener_pids; do
          case "$cmux_listener_pid" in
            ''|*[!0-9]*) continue ;;
          esac
          cmux_listener_command="$(printf '%s\\n' "$cmux_ps_output" | awk -v target="$cmux_listener_pid" '$1 == target { $1 = ""; $2 = ""; sub(/^[[:space:]]+/, ""); print; exit }')"
          case "$cmux_listener_command" in
            *sshd*|*ssh*) ;;
            *) continue ;;
          esac
          cmux_child_pids="$(printf '%s\\n' "$cmux_ps_output" | awk -v parent="$cmux_listener_pid" -v slot="$cmux_persistent_slot" '
            function clean_token(value) {
              gsub(/'\''/, "", value)
              gsub(/"/, "", value)
              gsub(/\\\\/, "", value)
              return value
            }
            function has_token(target, i) {
              for (i = 3; i <= NF; i++) {
                if (clean_token($i) == target) return 1
              }
              return 0
            }
            function next_value(after, i, value) {
              for (i = after + 1; i <= NF; i++) {
                value = clean_token($i)
                if (value != "") return value
              }
              return ""
            }
            function has_exact_slot(i, token, value) {
              for (i = 3; i <= NF; i++) {
                token = clean_token($i)
                if (token == "--slot") {
                  return next_value(i) == slot
                }
                if (token ~ /^--slot=/) {
                  value = substr(token, 8)
                  if (value != "") return value == slot
                  return next_value(i) == slot
                }
              }
              return 0
            }
            $2 == parent &&
            index($0, "cmuxd-remote") &&
            has_token("serve") &&
            has_token("--stdio") &&
            has_token("--persistent") &&
            has_exact_slot() &&
            $1 ~ /^[0-9]+$/ {
              print $1
            }
          ')"
          cmux_cleanup_reason=child
          if [ -z "$cmux_child_pids" ]; then
            cmux_cleanup_reason=metadata
            cmux_metadata_ok=0
            cmux_slot_file="$HOME/.cmux/relay/${cmux_relay_port}.slot"
            cmux_metadata_slot_ok=0
            if [ -r "$cmux_slot_file" ]; then
              cmux_stored_slot="$(tr -d '\\r\\n' < "$cmux_slot_file")"
              [ "$cmux_stored_slot" = "$cmux_persistent_slot" ] && cmux_metadata_slot_ok=1
            fi
            if [ "$cmux_metadata_slot_ok" -eq 1 ]; then
              cmux_daemon_map="$HOME/.cmux/relay/${cmux_relay_port}.daemon_path"
              cmux_auth_file="$HOME/.cmux/relay/${cmux_relay_port}.auth"
              if [ -r "$cmux_daemon_map" ]; then
                cmux_daemon_path="$(tr -d '\\r\\n' < "$cmux_daemon_map")"
                case "$cmux_daemon_path" in
                  *cmuxd-remote*) cmux_metadata_ok=1 ;;
                esac
              fi
              if [ "$cmux_metadata_ok" -ne 1 ] && [ -r "$cmux_auth_file" ]; then
                cmux_auth_payload="$(tr -d '\\r\\n' < "$cmux_auth_file")"
                case "$cmux_auth_payload" in
                  *relay_id*relay_token*) cmux_metadata_ok=1 ;;
                esac
              fi
            fi
            [ "$cmux_metadata_ok" -eq 1 ] || continue
          fi
          kill -TERM "$cmux_listener_pid" $cmux_child_pids 2>/dev/null || true
          for cmux_child_pid in $cmux_child_pids; do
            kill -0 "$cmux_child_pid" 2>/dev/null && kill -KILL "$cmux_child_pid" 2>/dev/null || true
          done
          kill -0 "$cmux_listener_pid" 2>/dev/null && kill -KILL "$cmux_listener_pid" 2>/dev/null || true
          cmux_child_list="$(printf '%s\\n' "$cmux_child_pids" | tr '\\n' ' ' | sed 's/[[:space:]]*$//')"
          printf 'cmux_stale_relay_killed pid=%s children=%s port=%s reason=%s\\n' "$cmux_listener_pid" "$cmux_child_list" "$cmux_relay_port" "$cmux_cleanup_reason"
        done
        """
    }

    static func normalizedPersistentDaemonSlotForRemoteCleanup(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed != ".",
              trimmed != "..",
              trimmed.range(of: "^[A-Za-z0-9._-]{1,128}$", options: .regularExpression) != nil else {
            return nil
        }
        return trimmed
    }

    static func remoteCLIWrapperScript() -> String {
        """
        #!/bin/sh
        set -eu

        daemon="$HOME/.cmux/bin/cmuxd-remote-current"
        socket_path="${CMUX_SOCKET_PATH:-}"
        if [ -z "$socket_path" ] && [ -r "$HOME/.cmux/socket_addr" ]; then
          socket_path="$(tr -d '\\r\\n' < "$HOME/.cmux/socket_addr")"
        fi

        if [ -n "$socket_path" ] && [ "${socket_path#/}" = "$socket_path" ] && [ "${socket_path#*:}" != "$socket_path" ]; then
          relay_port="${socket_path##*:}"
          relay_map="$HOME/.cmux/relay/${relay_port}.daemon_path"
          if [ -r "$relay_map" ]; then
            mapped_daemon="$(tr -d '\\r\\n' < "$relay_map")"
            if [ -n "$mapped_daemon" ] && [ -x "$mapped_daemon" ]; then
              daemon="$mapped_daemon"
            fi
          fi
        fi

        exec "$daemon" "$@"
        """
    }

    static func remoteCLIWrapperInstallScript(daemonRemotePath: String) -> String {
        let trimmedRemotePath = daemonRemotePath.trimmingCharacters(in: .whitespacesAndNewlines)
        let daemonPathExpression = remoteDaemonPathShellExpression(trimmedRemotePath)
        return """
        mkdir -p "$HOME/.cmux/bin" "$HOME/.cmux/relay"
        ln -sf \(daemonPathExpression) "$HOME/.cmux/bin/cmuxd-remote-current"
        wrapper_tmp="$HOME/.cmux/bin/.cmux-wrapper.tmp.$$"
        cat > "$wrapper_tmp" <<'CMUXWRAPPER'
        \(remoteCLIWrapperScript())
        CMUXWRAPPER
        chmod 755 "$wrapper_tmp"
        mv -f "$wrapper_tmp" "$HOME/.cmux/bin/cmux"
        """
    }

    static func remoteRelayMetadataInstallScript(
        daemonRemotePath: String,
        relayPort: Int,
        relayID: String,
        relayToken: String,
        persistentDaemonSlot: String? = nil
    ) -> String {
        let trimmedRemotePath = daemonRemotePath.trimmingCharacters(in: .whitespacesAndNewlines)
        let daemonPathExpression = remoteDaemonPathShellExpression(trimmedRemotePath)
        let slotMetadataLine: String
        if let slot = normalizedPersistentDaemonSlotForRemoteCleanup(persistentDaemonSlot) {
            slotMetadataLine = "printf '%s' \(slot.shellSingleQuoted) > \"$HOME/.cmux/relay/\(relayPort).slot\"\nchmod 600 \"$HOME/.cmux/relay/\(relayPort).slot\""
        } else {
            slotMetadataLine = "rm -f \"$HOME/.cmux/relay/\(relayPort).slot\""
        }
        let authPayload = """
        {"relay_id":"\(relayID)","relay_token":"\(relayToken)"}
        """
        return """
        umask 077
        mkdir -p "$HOME/.cmux" "$HOME/.cmux/relay"
        chmod 700 "$HOME/.cmux/relay"
        \(remoteCLIWrapperInstallScript(daemonRemotePath: trimmedRemotePath))
        printf '%s' \(daemonPathExpression) > "$HOME/.cmux/relay/\(relayPort).daemon_path"
        \(slotMetadataLine)
        cat > "$HOME/.cmux/relay/\(relayPort).auth" <<'CMUXRELAYAUTH'
        \(authPayload)
        CMUXRELAYAUTH
        chmod 600 "$HOME/.cmux/relay/\(relayPort).auth"
        printf '%s' '127.0.0.1:\(relayPort)' > "$HOME/.cmux/socket_addr"
        """
    }

    static func remoteDaemonPathShellExpression(_ remotePath: String) -> String {
        let trimmedRemotePath = remotePath.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedRemotePath.hasPrefix("/") {
            return trimmedRemotePath.shellSingleQuoted
        }
        return "\"$HOME/\(trimmedRemotePath)\""
    }
}
