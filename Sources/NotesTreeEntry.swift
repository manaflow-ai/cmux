import Foundation

/// One immediate child of a directory in the Notes tree (pre-node value type).
struct NotesTreeEntry: Equatable, Sendable {
    let name: String
    let path: String
    let kind: NotesTreeKind
}
