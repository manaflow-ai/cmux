import Foundation

/// A session folder on disk paired with its current marker, as collected by
/// ``NotesTreeStorage/collectSessionFolders(inRoot:maxDepth:)`` for the
/// live-refresh pass.
struct NotesSessionFolderRef: Equatable, Sendable {
    let directory: String
    let marker: NotesSessionMarker
}
