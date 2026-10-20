/// Protocol seam for panel restore metadata inspected by remote reconnect policy.
public protocol WorkspaceSessionRemoteRestorePanelSnapshot: Sendable {
    /// Terminal restore metadata for this panel, if the panel is a terminal.
    associatedtype TerminalSnapshot: WorkspaceSessionRemoteRestoreTerminalSnapshot

    /// Terminal restore metadata for this panel, if present.
    var terminal: TerminalSnapshot? { get }
}
