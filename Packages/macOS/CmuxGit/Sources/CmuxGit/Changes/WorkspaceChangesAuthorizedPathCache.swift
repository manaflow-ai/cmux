import Foundation

/// Short-lived authorization snapshots for chunked workspace-changes reads.
actor WorkspaceChangesAuthorizedPathCache {
    struct Snapshot: Sendable {
        let repoRoot: String
        let diffBase: String
        let currentPaths: Set<String>
        let basePaths: Set<String>
    }

    private struct Entry: Sendable {
        let snapshot: Snapshot
        let expiresAt: Date
    }

    private let timeToLive: TimeInterval
    private let now: @Sendable () -> Date
    private var entries: [String: Entry] = [:]

    init(
        timeToLive: TimeInterval = 15,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.timeToLive = timeToLive
        self.now = now
    }

    func snapshot(forRepoRoot repoRoot: String) -> Snapshot? {
        guard let entry = entries[repoRoot] else { return nil }
        guard entry.expiresAt > now() else {
            entries[repoRoot] = nil
            return nil
        }
        return entry.snapshot
    }

    func store(_ snapshot: Snapshot) {
        entries[snapshot.repoRoot] = Entry(
            snapshot: snapshot,
            expiresAt: now().addingTimeInterval(timeToLive)
        )
    }
}
