import Foundation

/// Receives each source profile's bookmarks after its batch is saved, so the
/// bookmarks model (owned by the bookmarks feature, not this module) shows
/// them. One call per source profile; a repeat import of the same
/// `source.sourceKey` replaces that source's bookmarks instead of adding a
/// second copy. Callers skip the call when the user did not pick bookmarks.
public protocol ImportedBookmarkSink: Sendable {
    func replaceImportedBookmarks(_ bookmarks: [ImportedBookmark], source: ImportSourceRecord) async throws
}
