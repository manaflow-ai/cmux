internal import Foundation

/// Builds a remote shell invocation that resolves and executes `tmux`.
///
/// Remote commands do not run through an interactive login shell, so Homebrew
/// and other user-local bin directories may be absent from `PATH`. This builder
/// gives native remote-tmux mirroring and terminal-attached tmux profiles one
/// shared executable-resolution contract.
public struct RemoteTmuxCommandBuilder: Sendable {
    /// Stable stderr marker emitted with exit status 127 when `tmux` is unavailable.
    public static let notFoundSentinel = "cmux-remote-tmux: tmux not found"

    private let arguments: [String]

    /// Creates a builder for one `tmux` argument vector.
    ///
    /// - Parameter arguments: Arguments passed to the resolved `tmux` executable.
    public init(arguments: [String]) {
        self.arguments = arguments
    }

    /// The argv used to run the resolver through `/bin/sh`.
    public var remoteCommandArguments: [String] {
        ["/bin/sh", "-c", Self.resolverShellScript, "cmux-remote-tmux"] + arguments
    }

    /// A shell-quoted command suitable for an OpenSSH remote-command string.
    public var remoteShellCommand: String {
        remoteCommandArguments.map(shellQuoted).joined(separator: " ")
    }

    private func shellQuoted(_ value: String) -> String {
        "'" + value.replacing("'", with: "'\\''") + "'"
    }

    // Keep this one physical line: the remote login shell parses it before /bin/sh -c runs.
    private static let resolverShellScript =
        "cmux_tmux=\"\"; " +
        "if command -v tmux >/dev/null 2>&1; then cmux_tmux=\"$(command -v tmux)\"; else " +
        "for cmux_dir in \"$HOME/.local/bin\" \"$HOME/bin\" /opt/homebrew/bin /usr/local/bin /opt/local/bin /usr/pkg/bin /snap/bin /usr/bin /bin; do " +
        "if [ -x \"$cmux_dir/tmux\" ]; then cmux_tmux=\"$cmux_dir/tmux\"; break; fi; done; " +
        "if [ -z \"$cmux_tmux\" ] && [ -x /usr/libexec/path_helper ]; then eval \"$(/usr/libexec/path_helper -s 2>/dev/null)\"; " +
        "if command -v tmux >/dev/null 2>&1; then cmux_tmux=\"$(command -v tmux)\"; fi; fi; fi; " +
        "if [ -n \"$cmux_tmux\" ]; then exec \"$cmux_tmux\" \"$@\"; fi; " +
        "printf '%s\\n' '\(notFoundSentinel)' >&2; exit 127"
}
