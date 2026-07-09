/// Where a requested file-explorer selection path lands among the visible
/// outline rows: either an exact-match row, or the deepest ancestor row when the
/// exact path is not currently shown.
///
/// The row-walk decision is a pure value transform over an ordered list of
/// `(row, path)` candidates: the app-side coordinator snapshots the
/// `NSOutlineView` rows into that list (skipping non-node rows) and applies the
/// returned `row`, so no AppKit or live state crosses this seam.
public struct FileExplorerSelectionResolution: Sendable, Equatable {
    /// The outline row to select.
    public let row: Int
    /// `true` when `row`'s path equals the requested path; `false` when `row` is
    /// the deepest ancestor of a requested path that is not itself visible.
    public let isExact: Bool

    private init(row: Int, isExact: Bool) {
        self.row = row
        self.isExact = isExact
    }

    /// Resolves `target` against `candidates` (an ordered `(row, path)` snapshot
    /// of the visible outline rows): returns the first exact-match row, otherwise
    /// the deepest ancestor row (longest ancestor path, first one winning ties),
    /// or `nil` when no row equals or contains `target`.
    public static func resolve(
        target: String,
        in candidates: [(row: Int, path: String)]
    ) -> FileExplorerSelectionResolution? {
        var bestAncestor: (row: Int, pathLength: Int)?
        for candidate in candidates {
            if candidate.path == target {
                return FileExplorerSelectionResolution(row: candidate.row, isExact: true)
            }
            if candidate.path.isFileExplorerAncestor(of: target) {
                let length = candidate.path.count
                if bestAncestor == nil || length > bestAncestor!.pathLength {
                    bestAncestor = (candidate.row, length)
                }
            }
        }
        guard let bestAncestor else { return nil }
        return FileExplorerSelectionResolution(row: bestAncestor.row, isExact: false)
    }
}
