import Foundation

/// Snapshot of everything a ``NotesTreeStore`` reload pass needs, captured on
/// the main thread before the off-main tree build so the build never touches
/// live store state.
struct NotesTreeReloadRequest: Sendable {
    var root: String
    var notesDirPath: String?
    var projectRoot: String?
    var workspaceAnchorId: String?
    var observedTerminals: [NotesTreeObservedTerminal]
    var observedSessionKeys: Set<String>
    var observedSessions: [NotesTreeObservedSession]
    var maxDepth: Int
    var nodeBudget: Int
    var sessionRowLimit: Int
    var maxWatchers: Int
}
