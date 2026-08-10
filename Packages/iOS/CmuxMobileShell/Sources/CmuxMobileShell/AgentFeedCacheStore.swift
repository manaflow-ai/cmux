import Foundation

/// Account/team-scoped, bounded disk cache for authenticated Feed snapshots.
actor AgentFeedCacheStore {
    private let directory: URL
    private let fileManager: FileManager
    private let maxMacCount = 20

    init(directory: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        self.directory = directory
            ?? URL.cachesDirectory.appending(path: "AgentFeed", directoryHint: .isDirectory)
    }

    func load(scopeKey: String) -> [AgentFeedCachedSnapshot] {
        guard let data = try? Data(contentsOf: fileURL(scopeKey: scopeKey)),
              let snapshots = try? JSONDecoder().decode([AgentFeedCachedSnapshot].self, from: data) else {
            return []
        }
        return Array(snapshots.sorted { $0.cachedAt > $1.cachedAt }.prefix(maxMacCount))
    }

    func upsert(_ snapshot: AgentFeedCachedSnapshot, scopeKey: String) {
        var snapshots = load(scopeKey: scopeKey)
        snapshots.removeAll { $0.ownerKey == snapshot.ownerKey }
        snapshots.insert(snapshot, at: 0)
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            try JSONEncoder().encode(Array(snapshots.prefix(maxMacCount)))
                .write(to: fileURL(scopeKey: scopeKey), options: .atomic)
        } catch {
            // Cache failure is non-fatal; the authenticated host remains authoritative.
        }
    }

    func clear(scopeKey: String) {
        try? fileManager.removeItem(at: fileURL(scopeKey: scopeKey))
    }

    func clearAll() {
        try? fileManager.removeItem(at: directory)
    }

    private func fileURL(scopeKey: String) -> URL {
        let filename = Data(scopeKey.utf8).base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "=", with: "")
        return directory.appending(path: "\(filename).json")
    }
}
