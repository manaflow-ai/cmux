import Foundation

/// An agent process seen running on one of the workspace's pane TTYs that has
/// no hook record (bare launches bypass the wrapper when the user's PATH or
/// alias shadows it), so its session id is unknown. The store resolves it
/// against the cwd's session files: the newest session of that agent active
/// since the process started is that pane's session.
struct NotesTreeAnonymousAgentObservation: Equatable, Sendable {
    var agent: String
    var startedAt: TimeInterval
    var surfaceAnchorId: String? = nil
    var terminalPanelId: String? = nil
}
