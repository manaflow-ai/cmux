@testable import CMUXAgentLaunch
import Foundation
import Testing

/// The revision counter is the phone feed's staleness contract: every item
/// mutation must bump it exactly once and fire the change hook, and
/// non-mutations must not.
@MainActor
@Suite("WorkstreamStore revision")
struct WorkstreamStoreRevisionTests {
    @Test("Ingest bumps the revision and fires the hook")
    func ingestBumpsRevision() {
        let store = WorkstreamStore(ringCapacity: 10)
        var observed: [Int] = []
        store.onRevisionChange = { observed.append($0) }

        #expect(store.revision == 0)
        store.ingest(.permissionEvent("s1", requestId: "r1"))
        #expect(store.revision == 1)
        store.ingest(.permissionEvent("s1", requestId: "r2"))
        #expect(store.revision == 2)
        #expect(observed == [1, 2])
    }

    @Test("Resolving and expiring bump once; repeats do not")
    func resolveAndExpireBumpOnce() throws {
        let store = WorkstreamStore(ringCapacity: 10)
        store.ingest(.permissionEvent("s1", requestId: "r1"))
        let itemId = try #require(store.items.first?.id)
        #expect(store.revision == 1)

        store.markResolved(itemId, decision: .permission(.once))
        #expect(store.revision == 2)
        // Already resolved: no further bump.
        store.markResolved(itemId, decision: .permission(.deny))
        #expect(store.revision == 2)
        store.markExpired(itemId)
        #expect(store.revision == 2)
    }

    @Test("Bulk expiry bumps only when something actually expired")
    func bulkExpiryBumpsOnlyOnChange() {
        let store = WorkstreamStore(ringCapacity: 10)
        store.expirePending(olderThan: 0)
        #expect(store.revision == 0)

        store.ingest(.permissionEvent("s1", requestId: "r1", ppid: 424_242))
        #expect(store.revision == 1)
        store.expireItems(forPpid: 424_242)
        #expect(store.revision == 2)
        store.expireItems(forPpid: 424_242)
        #expect(store.revision == 2)
    }
}

private extension WorkstreamEvent {
    static func permissionEvent(
        _ sessionId: String,
        requestId: String,
        ppid: Int? = nil
    ) -> WorkstreamEvent {
        WorkstreamEvent(
            sessionId: sessionId,
            hookEventName: .permissionRequest,
            source: "claude",
            cwd: "/tmp",
            toolName: "Write",
            toolInputJSON: "{}",
            requestId: requestId,
            ppid: ppid,
            receivedAt: Date()
        )
    }
}
