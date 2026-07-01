import Foundation

/// A pane-session observation handed to the store by the app layer (live
/// snapshots + the shared restorable-agent index).
struct NotesTreeObservedSession: Equatable, Sendable {
    var agent: String
    var sessionId: String
    var surfaceAnchorId: String?
    /// Terminal panel this live observation currently belongs to. Unlike
    /// `surfaceAnchorId`, this is present even before a pane has minted a
    /// notes anchor, so the tree can render the live terminal row as the
    /// active agent session without creating notes metadata.
    var terminalPanelId: String? = nil
}
