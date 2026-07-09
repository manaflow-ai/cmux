public import Foundation

/// A small shell wrapper that keeps a disconnected remote terminal visible.
///
/// Materializing the value writes a base64-wrapped POSIX `/bin/sh` script to a
/// uniquely named temp file (mode `0o700`) and returns its path. The returned
/// path is handed to `initialCommand`, which Ghostty runs as the PTY command.
/// The wrapper prints a localized disconnect banner, removes itself, and either
/// waits for Enter to drive a `workspace.remote.reconnect` RPC (when a
/// reconnect command is present) or parks reading until EOF.
///
/// The target and every banner string are base64-encoded and decoded inside the
/// shell so no value (`$(id)`, backticks, quotes, escape sequences, or a
/// translator's metacharacters) is ever interpreted as shell syntax.
public struct RemoteDisconnectPlaceholderScript {
    /// The localized banner strings rendered by the POSIX `printf` inside the
    /// wrapper. Resolved app-side so `String(localized:)` binds to the app
    /// bundle's localization tables (the package never localizes). All three use
    /// `%s` (not `%@`) because they are formatted by the shell, not by Swift.
    public struct Strings: Sendable, Equatable {
        /// Format for the disconnected line (`remote.disconnectBanner.sessionEnded`);
        /// `%s` is the disconnected target.
        public let sessionEndedFormat: String
        /// The Enter-to-reconnect hint (`remote.disconnectBanner.reconnectHint`).
        public let reconnectHint: String
        /// The reconnect-unavailable hint
        /// (`remote.disconnectBanner.reconnectUnavailableHint`).
        public let reconnectUnavailableHint: String

        /// Creates the banner strings with all three lines app-resolved.
        public init(
            sessionEndedFormat: String,
            reconnectHint: String,
            reconnectUnavailableHint: String
        ) {
            self.sessionEndedFormat = sessionEndedFormat
            self.reconnectHint = reconnectHint
            self.reconnectUnavailableHint = reconnectUnavailableHint
        }
    }

    /// The remote target shown in the disconnect banner.
    public let target: String
    /// The original cmux remote command re-run on a successful reconnect, or
    /// `nil` when reconnect is unavailable.
    public let reconnectCommand: String?
    /// The app-resolved banner strings.
    public let strings: Strings
    /// The file system used to resolve the temp directory and write the script.
    private let fileManager: FileManager

    /// Creates a placeholder-script builder for one disconnect.
    public init(
        target: String,
        reconnectCommand: String?,
        strings: Strings,
        fileManager: FileManager = .default
    ) {
        self.target = target
        self.reconnectCommand = reconnectCommand
        self.strings = strings
        self.fileManager = fileManager
    }

    /// Writes the wrapper to a temp file and returns its path, or `/bin/sh` if
    /// the write fails.
    public func materialize() -> String {
        let tempDir = fileManager.temporaryDirectory
        let scriptURL = tempDir.appendingPathComponent(
            "cmux-remote-disconnect-\(UUID().uuidString.lowercased()).sh"
        )
        // Encode the target as base64 and decode it inside the shell. This sidesteps every
        // layer of shell quoting: no matter what the target contains (`$(id)`, backticks,
        // single/double quotes, escape sequences), the shell never sees it as shell syntax.
        // Previous version only escaped backslash and double-quote, which left command
        // substitution and backticks as a live injection vector (Codex P2).
        let encodedTarget = Data(target.utf8).base64EncodedString()
        // Encode the localized lines the same way as the target, so a translator using
        // backticks or $(…) in a translation string can't unexpectedly execute in the
        // user's local shell. Decoded inline at wrapper startup, then fed to printf.
        let encodedEndedFormat = Data(strings.sessionEndedFormat.utf8).base64EncodedString()
        let encodedReconnectLine = Data(strings.reconnectHint.utf8).base64EncodedString()
        let encodedReconnectUnavailableLine = Data(strings.reconnectUnavailableHint.utf8).base64EncodedString()
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
        # Append newline + color codes ourselves rather than trusting the translator to
        # preserve them in every locale.
        printf '\\033[1;33m'
        printf "$cmux_disconnect_ended_format" "$cmux_disconnect_target"
        printf '\\033[0m\\n' >&2
        # Remove ourselves so /tmp doesn't accumulate these wrappers across sessions.
        rm -f -- "$0" 2>/dev/null || true
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
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: scriptURL.path)
            return scriptURL.path
        } catch {
            return "/bin/sh"
        }
    }
}
