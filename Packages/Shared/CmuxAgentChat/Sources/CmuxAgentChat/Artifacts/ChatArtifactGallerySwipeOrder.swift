/// The flattened visible-file order used by gallery viewer paging.
public struct ChatArtifactGallerySwipeOrder: Sendable, Equatable {
    /// Visible non-folder files in paging order.
    public let files: [ChatArtifactGalleryItem]

    /// Visible non-folder paths in paging order.
    public var paths: [String] { files.map(\.path) }

    /// Number of visible files in the paging order.
    public var count: Int { files.count }

    /// Creates a paging order by flattening visible groups in display order.
    ///
    /// Directory rows are excluded, and a repeated path keeps its first visible
    /// position.
    ///
    /// - Parameter groups: Filtered and sorted groups in display order.
    public init(groups: [ChatArtifactGalleryGroup]) {
        self.init(items: groups.flatMap(\.items))
    }

    /// Creates a paging order from one flat visible collection.
    ///
    /// - Parameter items: Filtered and sorted items in display order.
    public init(items: [ChatArtifactGalleryItem]) {
        var seenPaths: Set<String> = []
        files = items.filter { item in
            item.kind != .directory && seenPaths.insert(item.path).inserted
        }
    }

    /// Creates a paging order from terminal-scan references.
    ///
    /// - Parameter references: Visible terminal references in display order.
    public init(references: [TerminalArtifactReference]) {
        self.init(items: references.map { reference in
            ChatArtifactGalleryItem(
                path: reference.path,
                kind: reference.kind,
                displayName: reference.displayName,
                size: reference.size,
                modifiedAt: reference.modifiedAt
            )
        })
    }

    /// Returns the bounded previous/current/next window around one file.
    ///
    /// - Parameter path: Current visible file path.
    /// - Returns: At most three files, or an empty array for an unknown path.
    public func pageWindow(around path: String) -> [ChatArtifactGalleryItem] {
        guard let currentIndex = files.firstIndex(where: { $0.path == path }) else {
            return []
        }
        let lowerBound = currentIndex > files.startIndex
            ? files.index(before: currentIndex)
            : currentIndex
        let upperBound = files.index(
            after: currentIndex < files.index(before: files.endIndex)
                ? files.index(after: currentIndex)
                : currentIndex
        )
        return Array(files[lowerBound..<upperBound])
    }

    /// Returns the file before a visible path.
    ///
    /// - Parameter path: Current visible file path.
    /// - Returns: Previous path, or `nil` at the first file or for an unknown path.
    public func previousPath(before path: String) -> String? {
        guard let index = files.firstIndex(where: { $0.path == path }),
              index > files.startIndex else { return nil }
        return files[files.index(before: index)].path
    }

    /// Returns the file after a visible path.
    ///
    /// - Parameter path: Current visible file path.
    /// - Returns: Next path, or `nil` at the last file or for an unknown path.
    public func nextPath(after path: String) -> String? {
        guard let index = files.firstIndex(where: { $0.path == path }) else { return nil }
        let nextIndex = files.index(after: index)
        guard nextIndex < files.endIndex else { return nil }
        return files[nextIndex].path
    }
}
