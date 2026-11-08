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
        executableBuilder.remoteCommandArguments(arguments: arguments)
    }

    /// A shell-quoted command suitable for an OpenSSH remote-command string.
    public var remoteShellCommand: String {
        executableBuilder.remoteShellCommand(arguments: arguments)
    }

    private var executableBuilder: RemoteExecutableCommandBuilder {
        RemoteExecutableCommandBuilder(
            executableName: "tmux",
            notFoundSentinel: Self.notFoundSentinel
        )
    }
}
