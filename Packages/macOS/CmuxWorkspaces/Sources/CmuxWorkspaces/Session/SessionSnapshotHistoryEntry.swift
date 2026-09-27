public import Foundation

/// One archived session snapshot in the rotated history directory.
///
/// The archive time and richness live in the file name
/// (`session-<bundle>-<unix ms>-w<workspaces>-p<panels>.json`) so listing and
/// pruning never decode snapshot JSON.
public struct SessionSnapshotHistoryEntry: Equatable, Sendable {
    public var fileURL: URL
    public var archivedAt: Date
    public var richness: SessionSnapshotRichness

    public init(fileURL: URL, archivedAt: Date, richness: SessionSnapshotRichness) {
        self.fileURL = fileURL
        self.archivedAt = archivedAt
        self.richness = richness
    }

    static func fileName(safeBundleId: String, archivedAt: Date, richness: SessionSnapshotRichness) -> String {
        let millis = Int64((archivedAt.timeIntervalSince1970 * 1000).rounded())
        return "session-\(safeBundleId)-\(millis)-w\(richness.workspaces)-p\(richness.panels).json"
    }

    static func parse(fileURL: URL, safeBundleId: String) -> SessionSnapshotHistoryEntry? {
        let name = fileURL.lastPathComponent
        let prefix = "session-\(safeBundleId)-"
        guard name.hasPrefix(prefix), name.hasSuffix(".json") else { return nil }
        let body = name.dropFirst(prefix.count).dropLast(".json".count)
        let parts = body.split(separator: "-")
        guard parts.count == 3,
              let millis = Int64(parts[0]),
              parts[1].first == "w", let workspaces = Int(parts[1].dropFirst()),
              parts[2].first == "p", let panels = Int(parts[2].dropFirst()) else {
            return nil
        }
        return SessionSnapshotHistoryEntry(
            fileURL: fileURL,
            archivedAt: Date(timeIntervalSince1970: TimeInterval(millis) / 1000),
            richness: SessionSnapshotRichness(workspaces: workspaces, panels: panels)
        )
    }

    /// Chooses which entries to keep: the `limit` newest, except that the
    /// richest entry always survives. A run of trivial launches therefore
    /// cannot rotate the last full layout out of history.
    static func retained(_ entries: [SessionSnapshotHistoryEntry], limit: Int) -> [SessionSnapshotHistoryEntry] {
        let newestFirst = entries.sorted { $0.archivedAt > $1.archivedAt }
        guard limit > 0 else { return [] }
        guard newestFirst.count > limit else { return newestFirst }
        var kept = Array(newestFirst.prefix(limit))
        // Newest among the richest, so a tie keeps the most recent full layout.
        if let richest = newestFirst.max(by: { lhs, rhs in
            lhs.richness != rhs.richness ? lhs.richness < rhs.richness : lhs.archivedAt < rhs.archivedAt
        }), !kept.contains(richest) {
            kept[kept.count - 1] = richest
        }
        return kept
    }
}
