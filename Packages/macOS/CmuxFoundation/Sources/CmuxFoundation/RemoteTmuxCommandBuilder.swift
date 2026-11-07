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
    private let prunesOrphanedControlClients: Bool

    /// Creates a builder for one `tmux` argument vector.
    ///
    /// - Parameters:
    ///   - arguments: Arguments passed to the resolved `tmux` executable.
    ///   - prunesOrphanedControlClients: Kill the server's control-mode clients that
    ///     have been reparented to PID 1 before running `tmux`. A `tmux -CC` client
    ///     whose ssh session died while it was blocked writing output survives the
    ///     pty hangup and stays attached forever (issue #24388). Only the
    ///     control-stream attach should set this.
    public init(arguments: [String], prunesOrphanedControlClients: Bool = false) {
        self.arguments = arguments
        self.prunesOrphanedControlClients = prunesOrphanedControlClients
    }

    /// The argv used to run the resolver through `/bin/sh`.
    public var remoteCommandArguments: [String] {
        executableBuilder.remoteCommandArguments(arguments: arguments)
    }

    /// A shell-quoted command suitable for an OpenSSH remote-command string.
    public var remoteShellCommand: String {
        executableBuilder.remoteShellCommand(arguments: arguments)
    }

    private var executableBuilder: RemoteExecutableCommandBuilder {
        RemoteExecutableCommandBuilder(
            executableName: "tmux",
            notFoundSentinel: Self.notFoundSentinel,
            executionPrologue: prunesOrphanedControlClients ? Self.pruneOrphanedControlClientsScript : ""
        )
    }

    /// Kills control-mode clients of the default server whose parent is PID 1.
    ///
    /// Their ssh session is gone, so nothing will ever read their output again;
    /// `detach-client` does not end them, SIGTERM does. Skipped where sshd itself
    /// is PID 1 (a container), since every live client has that parent there, and
    /// wherever PID 1 cannot be identified (restricted `/proc`). Any failure (no
    /// server, no `ps`, no permission) leaves every client alone.
    static let pruneOrphanedControlClientsScript =
        "if cmux_init_comm=$(ps -o comm= -p 1 2>/dev/null) && " +
        "[ -n \"$cmux_init_comm\" ] && [ \"$cmux_init_comm\" != sshd ]; then " +
        "for cmux_client in $(\"$cmux_executable_path\" list-clients -F '#{client_pid}:#{client_control_mode}' 2>/dev/null); do " +
        "case \"$cmux_client\" in *:1) cmux_client_pid=${cmux_client%%:*}; " +
        "cmux_client_ppid=$(ps -o ppid= -p \"$cmux_client_pid\" 2>/dev/null); " +
        "while [ \"${cmux_client_ppid# }\" != \"$cmux_client_ppid\" ]; do cmux_client_ppid=${cmux_client_ppid# }; done; " +
        "if [ \"$cmux_client_ppid\" = 1 ]; then kill -TERM \"$cmux_client_pid\" 2>/dev/null; fi;; esac; done; fi; "
}
