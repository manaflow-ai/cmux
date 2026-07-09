import Foundation
import Testing
@testable import CmuxWorkspaces

/// A scripted host that records the coordinator's calls and returns canned
/// outcomes, so the three reopen/clear routing flows can be asserted on their
/// call sequence and return without any app types.
@MainActor
private final class FakeReopenHost: ClosedItemReopenHosting {
    typealias Manager = Int
    typealias RemovedRecord = UUID

    // Scripted inputs.
    var clearManagers: [Int] = []
    var legacyBrowserManagers: [Int] = []
    var legacyClosedAt: [Int: Date] = [:]
    var legacyStackReopens: Set<Int> = []
    /// Records (in order) the cutoffs the coordinator asks the store to restore
    /// newer-than; each maps to a scripted outcome.
    var storeOutcomes: [ClosedItemReopenStoreRestoreOutcome] = []
    var removedRecords: [UUID: UUID] = [:]
    var restorableRemovedRecords: Set<UUID> = []

    // Recorded effects.
    private(set) var calls: [String] = []
    private(set) var removedAll = false
    private(set) var clearedManagers: [Int] = []
    private(set) var excludingSnapshots: [Set<UUID>] = []
    private(set) var reinserted: [UUID] = []

    func removeAllClosedItemHistory() { removedAll = true; calls.append("removeAll") }

    func managersForClear(preferred: Int?) -> [Int] { clearManagers }

    func clearRecentlyClosedBrowserPanelHistory(_ manager: Int) {
        clearedManagers.append(manager)
        calls.append("clear:\(manager)")
    }

    func recentlyClosedLegacyBrowserManagers(preferred: Int?) -> [Int] { legacyBrowserManagers }

    func mostRecentLegacyClosedBrowserPanelClosedAt(_ manager: Int) -> Date? { legacyClosedAt[manager] }

    func restoreFirstRestorableStoreItem(
        newerThan cutoff: Date?,
        excluding: Set<UUID>,
        preferred: Int?,
        shouldActivate: Bool
    ) -> ClosedItemReopenStoreRestoreOutcome {
        excludingSnapshots.append(excluding)
        calls.append("storeRestore:\(cutoff.map { "\($0.timeIntervalSinceReferenceDate)" } ?? "nil")")
        guard !storeOutcomes.isEmpty else {
            return ClosedItemReopenStoreRestoreOutcome(didRestore: false, failedRecordIds: [])
        }
        return storeOutcomes.removeFirst()
    }

    func reopenMostRecentlyClosedBrowserPanelFromLegacyStack(_ manager: Int) -> Bool {
        calls.append("legacyStack:\(manager)")
        return legacyStackReopens.contains(manager)
    }

    func removeStoreRecord(id: UUID) -> UUID? {
        calls.append("removeRecord:\(id)")
        return removedRecords[id]
    }

    func restoreRemovedRecord(_ removed: UUID, preferred: Int?, shouldActivate: Bool) -> Bool {
        calls.append("restoreRemoved:\(removed)")
        return restorableRemovedRecords.contains(removed)
    }

    func reinsertRemovedRecord(_ removed: UUID) {
        reinserted.append(removed)
        calls.append("reinsert:\(removed)")
    }
}

@MainActor
@Suite struct ClosedItemReopenCoordinatorTests {
    @Test("clear removes all history then clears each manager once, deduped by identity")
    func clearDedupesManagers() {
        let host = FakeReopenHost()
        host.clearManagers = [1, 2, 1, 3, 2] // duplicates (preferred == root == registered)
        let coordinator = ClosedItemReopenCoordinator(host: host)

        coordinator.clearRecentlyClosedHistory(preferred: 1)

        #expect(host.removedAll)
        #expect(host.clearedManagers == [1, 2, 3]) // first-seen order, each once
        #expect(host.calls.first == "removeAll")
    }

    @Test("reopen-most-recent: a store hit newer than the first manager's cutoff wins immediately")
    func reopenStoreHitWinsFirst() {
        let host = FakeReopenHost()
        host.legacyBrowserManagers = [10, 11]
        host.legacyClosedAt = [10: Date(timeIntervalSinceReferenceDate: 100)]
        host.storeOutcomes = [
            ClosedItemReopenStoreRestoreOutcome(didRestore: true, failedRecordIds: [])
        ]
        let coordinator = ClosedItemReopenCoordinator(host: host)

        let reopened = coordinator.reopenMostRecentlyClosedItem(preferred: nil)

        #expect(reopened)
        // Only the first manager's store attempt ran; no legacy-stack pop, no
        // second manager, no nil-cutoff fallback.
        #expect(host.calls == ["storeRestore:100.0"])
    }

    @Test("reopen-most-recent: failed store ids accumulate into the exclusion set across the interleave")
    func reopenAccumulatesFailedRecordIds() {
        let host = FakeReopenHost()
        let failedA = UUID()
        let failedB = UUID()
        host.legacyBrowserManagers = [10, 11]
        host.legacyClosedAt = [
            10: Date(timeIntervalSinceReferenceDate: 200),
            11: Date(timeIntervalSinceReferenceDate: 100)
        ]
        // Manager 10: store fails (records failedA), legacy stack misses.
        // Manager 11: store fails (records failedB), legacy stack misses.
        // Final nil-cutoff store: succeeds.
        host.storeOutcomes = [
            ClosedItemReopenStoreRestoreOutcome(didRestore: false, failedRecordIds: [failedA]),
            ClosedItemReopenStoreRestoreOutcome(didRestore: false, failedRecordIds: [failedB]),
            ClosedItemReopenStoreRestoreOutcome(didRestore: true, failedRecordIds: [])
        ]
        let coordinator = ClosedItemReopenCoordinator(host: host)

        let reopened = coordinator.reopenMostRecentlyClosedItem(preferred: nil)

        #expect(reopened)
        // Three store attempts; each later one excludes every previously-failed id.
        #expect(host.excludingSnapshots.count == 3)
        #expect(host.excludingSnapshots[0] == [])
        #expect(host.excludingSnapshots[1] == [failedA])
        #expect(host.excludingSnapshots[2] == [failedA, failedB])
        #expect(host.calls == [
            "storeRestore:200.0", "legacyStack:10",
            "storeRestore:100.0", "legacyStack:11",
            "storeRestore:nil"
        ])
    }

    @Test("reopen-most-recent: a manager with no closed-browser timestamp is skipped")
    func reopenSkipsManagerWithoutTimestamp() {
        let host = FakeReopenHost()
        host.legacyBrowserManagers = [10]
        host.legacyClosedAt = [:] // manager 10 has no timestamp
        host.storeOutcomes = [
            ClosedItemReopenStoreRestoreOutcome(didRestore: false, failedRecordIds: [])
        ]
        let coordinator = ClosedItemReopenCoordinator(host: host)

        let reopened = coordinator.reopenMostRecentlyClosedItem(preferred: nil)

        #expect(!reopened)
        // The manager's whole turn is skipped; only the final nil-cutoff store ran.
        #expect(host.calls == ["storeRestore:nil"])
    }

    @Test("reopen-most-recent: a legacy-stack pop wins when the store misses for that manager")
    func reopenLegacyStackWins() {
        let host = FakeReopenHost()
        host.legacyBrowserManagers = [10]
        host.legacyClosedAt = [10: Date(timeIntervalSinceReferenceDate: 50)]
        host.legacyStackReopens = [10]
        host.storeOutcomes = [
            ClosedItemReopenStoreRestoreOutcome(didRestore: false, failedRecordIds: [])
        ]
        let coordinator = ClosedItemReopenCoordinator(host: host)

        let reopened = coordinator.reopenMostRecentlyClosedItem(preferred: nil)

        #expect(reopened)
        #expect(host.calls == ["storeRestore:50.0", "legacyStack:10"])
    }

    @Test("reopen-by-id: unknown id is a no-op false")
    func reopenByIdUnknownIsNoOp() {
        let host = FakeReopenHost()
        let coordinator = ClosedItemReopenCoordinator(host: host)

        let reopened = coordinator.reopenClosedHistoryItem(id: UUID())

        #expect(!reopened)
        #expect(host.calls.count == 1)
        #expect(host.reinserted.isEmpty)
    }

    @Test("reopen-by-id: a failed restore re-inserts the removed record")
    func reopenByIdFailureReinserts() {
        let host = FakeReopenHost()
        let id = UUID()
        let record = UUID()
        host.removedRecords = [id: record]
        host.restorableRemovedRecords = [] // restore fails
        let coordinator = ClosedItemReopenCoordinator(host: host)

        let reopened = coordinator.reopenClosedHistoryItem(id: id)

        #expect(!reopened)
        #expect(host.reinserted == [record])
        #expect(host.calls == ["removeRecord:\(id)", "restoreRemoved:\(record)", "reinsert:\(record)"])
    }

    @Test("reopen-by-id: a successful restore does not re-insert")
    func reopenByIdSuccessKeepsRecordRemoved() {
        let host = FakeReopenHost()
        let id = UUID()
        let record = UUID()
        host.removedRecords = [id: record]
        host.restorableRemovedRecords = [record] // restore succeeds
        let coordinator = ClosedItemReopenCoordinator(host: host)

        let reopened = coordinator.reopenClosedHistoryItem(id: id)

        #expect(reopened)
        #expect(host.reinserted.isEmpty)
    }
}
