/// Sequentially loads referenced gallery pages for complete filtering and sorting.
public struct ChatArtifactGalleryEagerPager: Sendable {
    /// Default maximum referenced rows retained during eager loading.
    public static let defaultMaximumReferencedRows = 2_000

    private let maximumReferencedRows: Int

    /// Creates an eager pager.
    ///
    /// - Parameter maximumReferencedRows: Maximum referenced rows to retain.
    public init(
        maximumReferencedRows: Int = Self.defaultMaximumReferencedRows
    ) {
        self.maximumReferencedRows = max(0, maximumReferencedRows)
    }

    /// Loads cursor pages sequentially until exhausted or capped.
    ///
    /// A repeated cursor ends the loop defensively while preserving that cursor
    /// for a later retry rather than issuing the same request indefinitely.
    ///
    /// - Parameters:
    ///   - initialSnapshot: First page or already accumulated gallery snapshot.
    ///   - fetchPage: Async operation for one opaque cursor.
    /// - Returns: The accumulated snapshot and cap status.
    /// - Throws: The first page-loading error or cancellation.
    public func loadRemaining(
        from initialSnapshot: ChatArtifactGallerySnapshot,
        fetchPage: @escaping @Sendable (_ cursor: String) async throws -> ChatArtifactGalleryPage
    ) async throws -> ChatArtifactGalleryEagerPagingResult {
        var snapshot = initialSnapshot.limitingReferenced(to: maximumReferencedRows)
        var seenCursors: Set<String> = []
        var truncatedRows = initialSnapshot.referenced.count > snapshot.referenced.count

        while let cursor = snapshot.nextCursor,
              snapshot.referenced.count < maximumReferencedRows,
              seenCursors.insert(cursor).inserted {
            try Task.checkCancellation()
            let page = try await fetchPage(cursor)
            try Task.checkCancellation()
            if page.requiresPagingRestart {
                return ChatArtifactGalleryEagerPagingResult(
                    snapshot: initialSnapshot,
                    reachedSafetyCap: false,
                    requiresPagingRestart: true
                )
            }
            let appended = snapshot.appending(page)
            truncatedRows = truncatedRows || appended.referenced.count > maximumReferencedRows
            snapshot = appended.limitingReferenced(to: maximumReferencedRows)
        }

        let hasMoreAtCap = snapshot.referenced.count >= maximumReferencedRows
            && snapshot.nextCursor != nil
        return ChatArtifactGalleryEagerPagingResult(
            snapshot: snapshot,
            reachedSafetyCap: truncatedRows || hasMoreAtCap
        )
    }
}
