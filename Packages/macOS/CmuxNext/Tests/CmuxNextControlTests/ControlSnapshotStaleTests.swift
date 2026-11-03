@testable import CmuxNextControl
import Foundation
import Testing

/// A control work-queue frame marks the snapshot stale (main-actor state changed: focus, selection) and the
/// next read builds it (`ControlSnapshotStore.fresh()`). Other publishes change one field and build no topology:
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
        store.setRefresher { await builds.build(store) }
        store.markStale()
        store.publish { $0.catalog.contextMask = 0b10 }
        _ = await store.fresh()
        #expect(await builds.count == 1, "the read after the context publish built nothing")
    }

    private actor BuildCounter {
        var count = 0
        func build(_ store: ControlSnapshotStore) {
            count += 1
            store.publish(rebuilt: true) { $0.topology = ControlTopology() }
        }
    }
}
