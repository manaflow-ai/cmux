internal import Foundation

/// Builds a terminal-attached tmux session launcher with shell integration.
///
/// A new session receives the supplied shell command for both its first pane
/// and future windows. An existing session is attached without changing any
/// of its options or already-running shells.
public struct RemoteTmuxSessionCommandBuilder: Sendable {
    private let sessionName: String
    private let shellCommand: String

    /// Creates a named tmux session launcher.
    ///
    /// - Parameters:
    ///   - sessionName: Validated exact tmux session name.
    ///   - shellCommand: Shell command used for panes in a newly created session.
    public init(sessionName: String, shellCommand: String) {
        self.sessionName = sessionName
        self.shellCommand = shellCommand
    }

    /// A shell-quoted command that creates or attaches to the named session.
    public var remoteShellCommand: String {
        let resolver = RemoteExecutableCommandBuilder(
            executableName: "tmux",
            notFoundSentinel: RemoteTmuxCommandBuilder.notFoundSentinel
        )
        let script = [
            "cmux_session_name=$1",
            "cmux_shell_command=$2",
            "cmux_session_target=\"=$cmux_session_name\"",
            "cmux_tmux=\"$(\(resolver.resolutionProbeShellCommand))\" || exit $?",
            "if \"$cmux_tmux\" has-session -t \"$cmux_session_target\" 2>/dev/null; then",
            "  exec \"$cmux_tmux\" attach-session -t \"$cmux_session_target\"",
            "fi",
            "if \"$cmux_tmux\" new-session -d -s \"$cmux_session_name\" \"$cmux_shell_command\"; then",
            "  \"$cmux_tmux\" set-option -t \"$cmux_session_target\" default-command \"$cmux_shell_command\" >/dev/null || exit $?",
            "fi",
            "exec \"$cmux_tmux\" attach-session -t \"$cmux_session_target\"",
        ].joined(separator: "\n")
        return ([
            "/bin/sh",
            "-c",
            script,
            "cmux-remote-tmux-session",
            sessionName,
            shellCommand,
        ])
        .map(Self.shellQuoted)
        .joined(separator: " ")
    }

    private static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
