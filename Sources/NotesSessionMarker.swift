import Foundation

/// Contents of a `_session.json` marker inside a session folder. Drives the
/// folder's session icon and the Resume action.
struct NotesSessionMarker: Codable, Equatable, Sendable {
    /// Agent identifier (`"claude"`, `"codex"`, …, or a registered agent id).
    var agent: String
    /// The agent's native session id (passed to its resume command).
    var sessionId: String
    /// The session's working directory.
    var cwd: String
    /// Display title for the session.
    var title: String
    /// Last-modified time of the session (Unix seconds); drives the relative
    /// timestamp and recency sort. Optional for backward-compatible decoding of
    /// markers written before this field existed.
    var modified: TimeInterval?
    /// True for folders the user explicitly filed into the Notes tree (for
    /// example by dragging a Vault/session row). Auto-discovered session
    /// folders stay on disk but are hidden from the current workspace tree, so
    /// historical panes do not read as current rows forever.
    var userCreated: Bool? = nil
}
