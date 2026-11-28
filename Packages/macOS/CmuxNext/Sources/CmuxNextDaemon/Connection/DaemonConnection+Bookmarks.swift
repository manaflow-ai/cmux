public import Foundation

/// Bookmarks in the home session (`bookmarks-v1`). Each wrapper throws
/// `missingCapabilities` on a daemon without it. Every write takes a
/// `MutationIdentity`: one per logical write, reused on its retries.
extension DaemonConnection {
    public var supportsBookmarks: Bool { identity?.supports(DaemonCapabilities.shared.bookmarks) == true }

    private func requireBookmarks() throws {
        guard supportsBookmarks else { throw DaemonError.missingCapabilities([DaemonCapabilities.shared.bookmarks]) }
    }

    public func listBookmarks(browserProfileID: String) async throws -> BookmarkList {
        try requireBookmarks()
        return try await request(ListBookmarksRequest(browserProfileID: browserProfileID))
    }

    @discardableResult
    public func createBookmark(_ request: CreateBookmarkRequest) async throws -> BookmarkResult {
        try requireBookmarks()
        return try await self.request(request)
    }

    @discardableResult
    public func updateBookmark(_ request: UpdateBookmarkRequest) async throws -> BookmarkResult {
        try requireBookmarks()
        return try await self.request(request)
    }

    @discardableResult
    public func moveBookmark(_ id: String, parent: String, index: Int, mutation: MutationIdentity) async throws -> BookmarkResult {
        try requireBookmarks()
        return try await request(MoveBookmarkRequest(bookmark: id, parent: parent, index: index, mutation: mutation))
    }

    @discardableResult
    public func deleteBookmark(_ id: String, mutation: MutationIdentity) async throws -> BookmarkDeletion {
        try requireBookmarks()
        return try await request(DeleteBookmarkRequest(bookmark: id, mutation: mutation))
    }

    @discardableResult
    public func importBookmarks(_ request: ImportBookmarksRequest) async throws -> BookmarkImportResult {
        try requireBookmarks()
        return try await self.request(request)
    }
}
