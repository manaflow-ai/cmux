/// The program family launched by a remote terminal profile.
public enum WorkspaceRemoteTerminalProfileKind: String, Codable, Sendable {
    /// Start the account's interactive login shell.
    case shell

    /// Create or attach to a named tmux session in the terminal.
    case tmux
}
