import Foundation

/// A flat note (`.cmux/notes/index.json` record) scoped to one workspace,
/// pre-resolved for the tree: display title, absolute body path, and the
/// surface anchor that links it to a pane (and thus possibly a session).
struct NotesFlatNoteRef: Equatable, Sendable {
    var title: String
    var path: String
    var surfaceAnchorId: String?
}
