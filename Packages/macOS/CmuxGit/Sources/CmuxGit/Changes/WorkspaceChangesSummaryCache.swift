import Foundation

/// A 15-second summary cache keyed by canonical repository root.
actor WorkspaceChangesSummaryCache {
    private struct Entry: Sendable {
        let summary: WorkspaceChangesSummary
        let storedAt: Duration
    }

    private let ttl: Duration
    private let clock: any WorkspaceChangesClock
    private var entries: [String: Entry] = [:]

    init(
        ttl: Duration = .seconds(15),
        clock: any WorkspaceChangesClock = SystemWorkspaceChangesClock()
    ) {
        self.ttl = ttl
        self.clock = clock
    }

    func summary(forRepoRoot repoRoot: String) async -> WorkspaceChangesSummary? {
        // Take the clock reading first: the entry must be read AFTER the
        // suspension point, or a fresher entry stored mid-await could be
        // validated against (and evicted for) a stale pre-await copy.
        let now = await clock.now()
        guard let entry = entries[repoRoot] else { return nil }
        guard now - entry.storedAt < ttl else {
            entries.removeValue(forKey: repoRoot)
            return nil
        }
        return entry.summary
    }

    func store(_ summary: WorkspaceChangesSummary, forRepoRoot repoRoot: String) async {
        entries[repoRoot] = Entry(summary: summary, storedAt: await clock.now())
    }
}
