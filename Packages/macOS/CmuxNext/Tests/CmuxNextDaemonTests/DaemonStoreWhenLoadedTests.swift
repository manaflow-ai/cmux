import Testing
@testable import CmuxNextDaemon

/// ``DaemonStore/whenLoaded(_:)`` runs in the turn the first live snapshot applies, never from a launch
/// snapshot, and at once once loaded: window restore starts there, not a main-queue drain later.
@MainActor
struct DaemonStoreWhenLoadedTests {
    @Test func runsInTheFirstLiveSnapshotsTurnOnce() {
        let store = DaemonStore()
        var runs = 0
        store.whenLoaded { runs += 1 }
        store.applyProvisional(snapshot: DaemonTree(workspaces: []))
        #expect(runs == 0, "a launch snapshot is not the live tree")
        store.apply(snapshot: DaemonTree(workspaces: []))
        #expect(runs == 1, "it runs before apply returns")
        store.apply(snapshot: DaemonTree(workspaces: []))
        #expect(runs == 1, "a later snapshot does not run it again")
    }

    @Test func runsAtOnceWhenAlreadyLoaded() {
        let store = DaemonStore()
        store.apply(snapshot: DaemonTree(workspaces: []))
        var ran = false
        store.whenLoaded { ran = true }
        #expect(ran)
    }
}
