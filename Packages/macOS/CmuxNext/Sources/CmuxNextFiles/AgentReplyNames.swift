import CmuxNextWakeups
public import Foundation

/// Finds the files a reply names without a folder (`next-sync.py` for `scripts/next-sync.py`)
/// inside a chat's folders, for its path chips (``AgentPaneReplyLinks/findByName``). One
/// ``FolderNameIndex`` walk per folder, built off the main thread and bounded, shared by every
/// chat of the app and kept for a short while, so a reply's chips and the click that follows use
/// one walk. Like Finder's search the walk skips hidden folders and the inside of packages, and
/// here generated trees (`node_modules`) too. The home folder and its parents are never walked.
/// The agent pane still checks every found file against the deny list and the roots. The App
/// makes one (`AppServices.agentReplyNames`) and every chat's links use it.
@MainActor
public final class AgentReplyNames {
    /// The most entries one folder's walk reads (the index then misses the rest).
    nonisolated static let entryLimit = 200_000
    /// Generated folders that are neither indexed nor walked into.
    nonisolated static let skippedFolders: Set<String> = ["node_modules", "DerivedData", "Pods", "build", "dist", "target"]
    /// How long a folder's index answers before the next search walks it again.
    static let freshFor: Duration = .seconds(30)
    /// The most folders whose index is kept (each is about 60 bytes per entry).
    static let keptFolders = 4
    /// Exact-name matches returned per name, best first.
    nonisolated static let hitsPerName = 20

    private var indexes: [String: (index: FolderNameIndex, built: ContinuousClock.Instant)] = [:]
    /// The walk of each folder in flight: a second search of that folder awaits it.
    private var building: [String: Task<FolderNameIndex?, Never>] = [:]
    /// Lets go of the indexes once they are past ``freshFor``, also when no search follows.
    private let expiry = DemandTimer(owner: "AgentReplyNames.expiry")
    private let home: String

    public init(home: String = NSHomeDirectory()) {
        self.home = URL(fileURLWithPath: home).resolvingSymlinksInPath().path
    }

    /// The files named like each of `names` inside `roots`, best first: the fewest folders below
    /// their root, then the shorter path, then by path.
    public func find(_ names: [String], in roots: [String]) async -> [String: [String]] {
        dropExpired()
        var hits: [String: [(relative: String, path: String)]] = [:]
        for root in roots where !Self.isTooBroad(root, home: home) {
            guard let index = await index(for: root) else { continue }
            for name in names {
                hits[name, default: []] += Self.files(named: name, in: index).map { ($0.relativePath, $0.url.path) }
            }
        }
        // Ranked across every root first, then cut: the best few, not the first few found.
        return hits.mapValues { Self.ranked($0).prefix(Self.hitsPerName).map(\.path) }
    }

    /// The home folder, a folder above it, and `/` hold far more than a project: never walked
    /// (their Library and cloud folders can be slow or ask for privacy access).
    nonisolated static func isTooBroad(_ root: String, home: String) -> Bool {
        root == "/" || root == home || home.hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }

    nonisolated static func ranked(_ hits: [(relative: String, path: String)]) -> [(relative: String, path: String)] {
        hits.sorted { a, b in
            let (da, db) = (a.relative.split(separator: "/").count, b.relative.split(separator: "/").count)
            if da != db { return da < db }
            if a.relative.count != b.relative.count { return a.relative.count < b.relative.count }
            return a.path < b.path
        }
    }

    /// The files of `index` whose name is `name` (case-insensitive, as the file system is). The
    /// search returns at most 2,000 exact names, shortest path first, so a tree with more files of
    /// one name than that (thousands of `index.ts`) may miss a deep one; the best ones are kept.
    nonisolated static func files(named name: String, in index: FolderNameIndex) -> [FolderNameIndex.Hit] {
        index.search(name, limit: 2_000).filter { !$0.isDirectory && $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    /// Lets go of indexes past ``freshFor`` (each can hold tens of MB) before any search.
    private func dropExpired() {
        let now = ContinuousClock.now
        indexes = indexes.filter { now - $0.value.built < Self.freshFor }
    }

    private func index(for root: String) async -> FolderNameIndex? {
        if let cached = indexes[root], ContinuousClock.now - cached.built < Self.freshFor { return cached.index }
        if let running = building[root] { return await running.value }
        // task-owner: `building` holds the walk until it ends; every search of this folder awaits it.
        let walk = Task { await Self.build(root) }
        building[root] = walk
        let index = await walk.value
        building[root] = nil
        guard let index else { return nil }
        let now = ContinuousClock.now
        dropExpired()
        if indexes.count >= Self.keptFolders, let oldest = indexes.min(by: { $0.value.built < $1.value.built })?.key {
            indexes[oldest] = nil
        }
        indexes[root] = (index, now)
        expiry.schedule(after: Self.freshFor) { @MainActor [weak self] in self?.dropExpired() }
        return index
    }

    @concurrent nonisolated private static func build(_ root: String) async -> FolderNameIndex? {
        try? FolderNameIndex.build(root: URL(fileURLWithPath: root, isDirectory: true), entryLimit: entryLimit,
                                   skippingFolders: skippedFolders)
    }
}
