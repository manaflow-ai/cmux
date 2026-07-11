import Foundation

extension Workspace {
    /// Writes a small shell wrapper that keeps a disconnected remote terminal visible.
    /// Returned path goes to `initialCommand`, which Ghostty runs as the PTY command.
    static func remoteDisconnectPlaceholderScript(target: String, reconnectCommand: String?) -> String {
        let scriptURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "cmux-remote-disconnect-\(UUID().uuidString.lowercased()).sh"
        )
        // Base64 keeps targets and localized text out of shell syntax, even if they contain
        // substitutions, backticks, quotes, or escape sequences.
        let encodedTarget = Data(target.utf8).base64EncodedString()
        let endedLineFormat = String(
            localized: "remote.disconnectBanner.sessionEnded",
            defaultValue: "[cmux] remote session disconnected: %s"
        )
        let reconnectLine = String(
            localized: "remote.disconnectBanner.reconnectHint",
            defaultValue: "[cmux] Press Enter to reconnect. This terminal will stay disconnected until then."
        )
        let reconnectUnavailableLine = String(
            localized: "remote.disconnectBanner.reconnectUnavailableHint",
            defaultValue: "[cmux] Reconnect this workspace from the sidebar or by running the original cmux remote command again."
        )
        let encodedEndedFormat = Data(endedLineFormat.utf8).base64EncodedString()
        let encodedReconnectLine = Data(reconnectLine.utf8).base64EncodedString()
        let encodedReconnectUnavailableLine = Data(reconnectUnavailableLine.utf8).base64EncodedString()
        let encodedReconnectCommand = Data((reconnectCommand ?? "").utf8).base64EncodedString()
        let body = """
        #!/bin/sh
        cmux_disconnect_decode() {
          printf '%s' "$1" | base64 --decode 2>/dev/null || printf '%s' "$1" | base64 -D 2>/dev/null
        }
        cmux_disconnect_target="$(cmux_disconnect_decode '\(encodedTarget)')"
        cmux_disconnect_ended_format="$(cmux_disconnect_decode '\(encodedEndedFormat)')"
        cmux_disconnect_reconnect_line="$(cmux_disconnect_decode '\(encodedReconnectLine)')"
        cmux_disconnect_reconnect_unavailable_line="$(cmux_disconnect_decode '\(encodedReconnectUnavailableLine)')"
        cmux_disconnect_reconnect_command="$(cmux_disconnect_decode '\(encodedReconnectCommand)')"
        cmux_disconnect_scrollback_file="${CMUX_RESTORE_SCROLLBACK_FILE:-}"
        if [ -n "$cmux_disconnect_scrollback_file" ] && [ -f "$cmux_disconnect_scrollback_file" ]; then
          /bin/cat -- "$cmux_disconnect_scrollback_file" 2>/dev/null || true
          printf '\\n'
          /bin/rm -f -- "$cmux_disconnect_scrollback_file" 2>/dev/null || true
          unset CMUX_RESTORE_SCROLLBACK_FILE
        fi
        # Append newline + color codes ourselves rather than trusting the translator to
        # preserve them in every locale.
        printf '\\033[1;33m'
        printf "$cmux_disconnect_ended_format" "$cmux_disconnect_target"
        printf '\\033[0m\\n' >&2
        # Remove ourselves so /tmp doesn't accumulate these wrappers across sessions.
        /bin/rm -f -- "$0" 2>/dev/null || true
        if [ -n "$cmux_disconnect_reconnect_command" ]; then
          printf '\\033[2m%s\\033[0m\\n\\n' "$cmux_disconnect_reconnect_line" >&2
          IFS= read -r _ || exit 0
          cmux_reconnect_cli="${CMUX_BUNDLED_CLI_PATH:-}"
          if [ -z "$cmux_reconnect_cli" ] || [ ! -x "$cmux_reconnect_cli" ]; then
            cmux_reconnect_cli="$(command -v cmux 2>/dev/null || true)"
          fi
          cmux_reconnect_socket="${CMUX_SOCKET_PATH:-${CMUX_SOCKET:-}}"
          if [ -n "$cmux_reconnect_cli" ] && [ -n "$cmux_reconnect_socket" ] && [ -n "${CMUX_WORKSPACE_ID:-}" ]; then
            cmux_reconnect_payload="{\\"workspace_id\\":\\"$CMUX_WORKSPACE_ID\\""
            if [ -n "${CMUX_SURFACE_ID:-}" ]; then
              cmux_reconnect_payload="$cmux_reconnect_payload,\\"surface_id\\":\\"$CMUX_SURFACE_ID\\""
            fi
            cmux_reconnect_payload="$cmux_reconnect_payload}"
            if "$cmux_reconnect_cli" --socket "$cmux_reconnect_socket" rpc workspace.remote.reconnect "$cmux_reconnect_payload" >/dev/null 2>&1; then
              exec /bin/sh -lc "$cmux_disconnect_reconnect_command"
            fi
          fi
          printf '\\033[2m%s\\033[0m\\n' "$cmux_disconnect_reconnect_unavailable_line" >&2
          while IFS= read -r _; do :; done
          exit 0
        fi
        printf '\\033[2m%s\\033[0m\\n' "$cmux_disconnect_reconnect_unavailable_line" >&2
        while IFS= read -r _; do :; done
        exit 0

        """
        do {
            try body.write(to: scriptURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: scriptURL.path)
            return scriptURL.path
        } catch {
            return "/bin/sh"
        }
    }
}
