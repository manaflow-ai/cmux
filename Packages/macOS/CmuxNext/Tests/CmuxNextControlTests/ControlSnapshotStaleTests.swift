@testable import CmuxNextControl
import CmuxNextCompat
import Foundation
import Testing

/// A control work-queue frame marks the snapshot stale (main-actor state changed: focus, selection) and the
/// next read builds it (`ControlSnapshotStore.fresh(deadline:)`). Other publishes change one field and build no topology:
/// the context mask the registry bridge publishes a turn after a focus change, a catalog refresh, settings. They
/// cleared the stale mark, so the next reads got the topology from before the change: the STRESS builder's
/// `pane.focus` ran, the window's focus machine moved, and `snapshot.get` kept the old focused pane for 10 s
/// ("focus never reached pane", e7a0de6d717 and bb1dc8698bf, macOS 27).
@Suite struct ControlSnapshotStaleTests {
    @Test func aContextMaskPublishLeavesAStaleSnapshotStale() {
        let store = ControlSnapshotStore()
        store.markStale()
        store.publish { $0.catalog.contextMask = 0b10 }
        #expect(store.isStale, "a publish of one field cleared the stale mark, so no read builds the topology")
    }

    @Test func theTopologyPublishClearsTheMark() {
        let store = ControlSnapshotStore()
        store.markStale()
        store.publish(rebuilt: true) { $0.topology = ControlTopology() }
        #expect(!store.isStale)
    }

    @Test func aReadAfterAContextPublishBuildsTheTopology() async {
        let store = ControlSnapshotStore()
        let builds = BuildCounter()
        store.setRefresher { builds.build(store) }
        store.markStale()
        store.publish { $0.catalog.contextMask = 0b10 }
        _ = await store.fresh(deadline: .now + .seconds(30))
        #expect(await builds.count == 1, "the read after the context publish built nothing")
    }

    /// A reader that starts waiting calls the `waiterAdded` hook (the App raises its pending publish there): a hook
    /// that publishes resolves the wait at once instead of at its deadline.
    @Test func aReaderThatStartsWaitingCallsTheWaiterAddedHook() async {
        let store = ControlSnapshotStore()
        let calls = HookCalls()
        store.setRefresher(nil, waiterAdded: {
            calls.count.withLock { $0 += 1 }
            store.publish { _ in }
        })
        let snapshot = await store.snapshot(where: { $0.generation >= 1 }, deadline: .now + .seconds(30))
        #expect(snapshot != nil, "the hook was not called, so nothing published for the waiter")
        #expect(calls.count.withLock { $0 } == 1)
    }

    /// A read of a stale snapshot whose build never comes (the main thread is stalled) returns the last published
    /// snapshot at its deadline.
    @Test func aStaleReadReturnsTheLastPublishedSnapshotAtItsDeadline() async {
        let store = ControlSnapshotStore()
        store.setRefresher(nil, waiterAdded: {})
        store.publish { $0.catalog.contextMask = 0b1 }
        store.markStale()
        let snapshot = await store.fresh(deadline: .now + .milliseconds(50))
        #expect(snapshot.catalog.contextMask == 0b1)
        #expect(store.isStale)
    }

    private final class HookCalls: Sendable {
        let count = Mutex(0)
    }

    @MainActor private final class BuildCounter {
        var count = 0
        func build(_ store: ControlSnapshotStore) {
            count += 1
            store.publish(rebuilt: true) { $0.topology = ControlTopology() }
        }
    }
}
