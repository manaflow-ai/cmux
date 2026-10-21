import CmuxNextFiles
import Foundation

/// Finds the files a reply names without a folder (`next-sync.py` for `scripts/next-sync.py`)
/// inside a chat's folders, for its path chips (``AgentPaneReplyLinks/findByName``). One
/// ``FolderNameIndex`` walk per folder, built off the main thread and bounded, kept for a short
/// while so a reply's chips and the click that follows share it. Like Finder's search the walk
/// skips hidden folders and the inside of packages; the agent pane still checks every found file
/// against the deny list and the roots.
@MainActor
final class AgentReplyNames {
    /// The most entries one folder's walk reads (the index then misses the rest).
    nonisolated static let entryLimit = 200_000
    /// How long a folder's index answers before the next search walks it again.
    static let freshFor: Duration = .seconds(30)
    /// Matches kept per name, best ranked by the pane.
    nonisolated static let hitsPerName = 20

    private var indexes: [String: (index: FolderNameIndex, built: ContinuousClock.Instant)] = [:]

    func find(_ names: [String], in roots: [String]) async -> [String: [String]] {
        var out: [String: [String]] = [:]
        for root in roots {
            guard let index = await index(for: root) else { continue }
            for name in names {
                out[name, default: []] += Self.files(named: name, in: index)
            }
        }
        return out
    }

    /// The files of `index` whose name is `name` (case-insensitive, as the file system is).
    nonisolated static func files(named name: String, in index: FolderNameIndex) -> [String] {
        index.search(name, limit: hitsPerName * 4)
            .filter { !$0.isDirectory && $0.name.caseInsensitiveCompare(name) == .orderedSame }
            .prefix(hitsPerName)
            .map(\.url.path)
    }

    private func index(for root: String) async -> FolderNameIndex? {
        let now = ContinuousClock.now
        if let cached = indexes[root], now - cached.built < Self.freshFor { return cached.index }
        guard let index = await Self.build(root) else { return nil }
        indexes[root] = (index, now)
        return index
    }

    @concurrent nonisolated private static func build(_ root: String) async -> FolderNameIndex? {
        try? FolderNameIndex.build(root: URL(fileURLWithPath: root, isDirectory: true), entryLimit: entryLimit)
    }
}
