internal import Foundation

/// Builds a terminal-attached tmux session launcher with shell integration.
///
/// A new session receives the supplied shell command for both its first pane
/// and future windows. Before attaching an existing session, its cmux workspace
/// environment is rebound to the current relay without changing user options
/// or already-running commands.
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
        var scriptLines = [
            "cmux_session_name=$1",
            "cmux_shell_command=$2",
            "cmux_session_target=\"=$cmux_session_name\"",
            "cmux_tmux=\"$(\(resolver.resolutionProbeShellCommand))\" || exit $?",
            "if \"$cmux_tmux\" has-session -t \"$cmux_session_target\" 2>/dev/null; then",
        ]
        scriptLines.append(contentsOf: Self.workspaceEnvironmentRebindingLines.map { "  " + $0 })
        scriptLines += [
            "  exec \"$cmux_tmux\" attach-session -t \"$cmux_session_target\"",
            "fi",
            "if \"$cmux_tmux\" new-session -d \(Self.newSessionEnvironmentArguments) -s \"$cmux_session_name\" \"$cmux_shell_command\"; then",
        ]
        scriptLines.append(contentsOf: Self.workspaceEnvironmentRebindingLines.map { "  " + $0 })
        scriptLines += [
            "  \"$cmux_tmux\" set-option -t \"$cmux_session_target:\" default-command \"$cmux_shell_command\" >/dev/null || exit $?",
            "fi",
            "exec \"$cmux_tmux\" attach-session -t \"$cmux_session_target\"",
        ]
        let script = scriptLines.joined(separator: "\n")
        return ([
            "/bin/sh",
            "-c",
            script,
            "cmux-remote-tmux-session",
            sessionName,
            shellCommand,
        ])
        .map(\.remoteCommandShellQuoted)
        .joined(separator: " ")
    }

    private static let workspaceEnvironmentKeys = [
        "CMUX_BUNDLED_CLI_PATH",
        "CMUX_SHELL_INTEGRATION",
        "CMUX_SHELL_INTEGRATION_DIR",
        "CMUX_SOCKET_PATH",
        "CMUX_TAB_ID",
        "CMUX_WORKSPACE_ID",
    ]

    private static let surfaceEnvironmentKeys = [
        "CMUX_PANEL_ID",
        "CMUX_SURFACE_ID",
    ]

    private static let transientEnvironmentKeys = [
        "CMUX_INITIAL_COMMAND_FILE",
    ]

    private static var workspaceEnvironmentRebindingLines: [String] {
        workspaceEnvironmentKeys.map { key in
            "if [ \"${\(key)+x}\" = x ]; then \"$cmux_tmux\" set-environment -t \"$cmux_session_target\" \(key) \"$\(key)\" >/dev/null || exit $?; else \"$cmux_tmux\" set-environment -t \"$cmux_session_target\" -u \(key) >/dev/null || exit $?; fi"
        } + transientEnvironmentClearingLines + surfaceEnvironmentClearingLines
    }

    private static var newSessionEnvironmentArguments: String {
        let workspaceArguments = workspaceEnvironmentKeys.map { key in
            "-e \"\(key)=${\(key)-}\""
        }
        let transientArguments = transientEnvironmentKeys.map { key in
            "-e \"\(key)=${\(key)-}\""
        }
        let surfaceArguments = surfaceEnvironmentKeys.map { key in
            "-e \"\(key)=\""
        }
        return (workspaceArguments + transientArguments + surfaceArguments).joined(separator: " ")
    }

    private static var transientEnvironmentClearingLines: [String] {
        transientEnvironmentKeys.map { key in
            "\"$cmux_tmux\" set-environment -t \"$cmux_session_target\" -u \(key) >/dev/null || exit $?"
        }
    }

    private static var surfaceEnvironmentClearingLines: [String] {
        surfaceEnvironmentKeys.map { key in
            "\"$cmux_tmux\" set-environment -t \"$cmux_session_target\" -u \(key) >/dev/null || exit $?"
        }
    }
}
