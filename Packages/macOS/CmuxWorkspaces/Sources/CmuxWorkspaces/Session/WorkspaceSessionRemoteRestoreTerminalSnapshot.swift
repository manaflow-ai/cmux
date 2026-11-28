/// Protocol seam for terminal-specific remote restore metadata.
public protocol WorkspaceSessionRemoteRestoreTerminalSnapshot: Sendable {
    /// Whether the snapshot represents a remote terminal.
    var isRemoteTerminal: Bool? { get }
    /// Persisted remote PTY session identifier, if present.
    var remotePTYSessionID: String? { get }
}
