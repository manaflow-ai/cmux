import Foundation

/// One agent session known to belong to this workspace (it ran in one of the
/// workspace's panes). Persisted inside `_workspace.json`.
struct NotesWorkspaceSessionRecord: Codable, Equatable, Sendable {
    var agent: String
    var sessionId: String
    /// The pane's note anchor (`Workspace.noteAnchorIdsByPanelId`) when one was
    /// minted — links pane-attached flat notes to this session for nesting.
    var surfaceAnchorId: String?
    var title: String
    var cwd: String
    /// Session recency (Unix seconds), hydrated from the live session stores.
    var modified: TimeInterval
    /// When this workspace last observed the session running in a pane.
    var lastSeen: TimeInterval
}
