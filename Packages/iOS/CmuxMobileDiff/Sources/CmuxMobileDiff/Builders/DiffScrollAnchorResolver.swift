/// Resolves stable list anchors across unified/split projections and row splices.
struct DiffScrollAnchorResolver: Sendable {
    private let rowBuilder = DiffRowBuilder()

    /// Creates an anchor resolver.
    init() {}

    /// Maps a unified or split source identity into the active projection.
    /// - Parameters:
    ///   - anchor: Current row or file identity.
    ///   - visibleFilePath: Last file known to contain the visible row.
    ///   - files: Current immutable file snapshots.
    ///   - mode: Destination projection mode.
    /// - Returns: A destination row identity, falling back to the file header.
    func resolvedAnchor(
        _ anchor: String?,
        visibleFilePath: String?,
        files: [DiffFileSnapshot],
        mode: DiffRenderingMode
    ) -> String? {
        guard let anchor else { return visibleFilePath }
        if files.contains(where: { $0.path == anchor }) { return anchor }
        for file in files {
            let rows = rowBuilder.projectedRows(file.rows, mode: mode)
            if let projected = rows.first(where: { $0.sourceRowIDs.contains(anchor) }) {
                return projected.id
            }
        }
        return visibleFilePath
    }

    /// Returns whether an anchor still represents a visible header or row.
    func containsVisibleAnchor(
        _ anchor: String?,
        files: [DiffFileSnapshot],
        mode: DiffRenderingMode
    ) -> Bool {
        guard let anchor else { return false }
        if files.contains(where: { $0.path == anchor }) { return true }
        return files.contains { file in
            guard !file.isCollapsed else { return false }
            return rowBuilder.projectedRows(file.rows, mode: mode).contains {
                $0.id == anchor || $0.sourceRowIDs.contains(anchor)
            }
        }
    }

    /// Finds the file that owns a unified or projected row identity.
    func filePath(containing anchor: String?, files: [DiffFileSnapshot]) -> String? {
        guard let anchor else { return nil }
        if files.contains(where: { $0.path == anchor }) { return anchor }
        if let file = files
            .filter({ anchor.hasSuffix("/\($0.path)") })
            .max(by: { $0.path.count < $1.path.count }) {
            return file.path
        }
        return files.first { file in
            file.rows.contains { $0.id == anchor || $0.sourceRowIDs.contains(anchor) }
        }?.path
    }
}
