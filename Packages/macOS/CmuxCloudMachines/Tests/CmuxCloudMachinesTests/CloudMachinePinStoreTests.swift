import Foundation
import Testing
@testable import CmuxCloudMachines

@MainActor
struct CloudMachinePinStoreTests {
    @MainActor
    private final class Scope {
        var value: String? = "user:a|team:one"
    }

    private func makeDefaults() -> (UserDefaults, String) {
        let suite = "cloud-machine-pins-\(UUID().uuidString)"
        return (UserDefaults(suiteName: suite)!, suite)
    }

    @Test func pinsPersistPerAccountAndTeamAndKeepStableOrder() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let scope = Scope()
        let first = CloudMachinePinStore(defaults: defaults, scopeProvider: { scope.value })
        first.reconcile(machineIDs: ["b", "a", "c"])
        first.setPinned(true, machineID: "c")
        first.setPinned(true, machineID: "a")
        #expect(first.orderedMachineIDs(["b", "a", "c"]) == ["c", "a", "b"])
        #expect(first.pinnedMachineIDs == ["a", "c"])

        let restored = CloudMachinePinStore(defaults: defaults, scopeProvider: { scope.value })
        #expect(restored.orderedMachineIDs(["a", "b", "c"]) == ["c", "a", "b"])
        scope.value = "user:a|team:two"
        restored.refreshScope()
        #expect(restored.pinnedMachineIDs.isEmpty)
        #expect(restored.orderedMachineIDs(["a", "b", "c"]) == ["a", "b", "c"])
        scope.value = "user:a|team:one"
        restored.refreshScope()
        #expect(restored.isPinned("c"))
        restored.reconcile(machineIDs: ["a", "c"])
        #expect(restored.orderedMachineIDs(["a", "c"]) == ["c", "a"])
    }

    @Test func newMachinesAppendAfterRefreshAndRelaunchWithoutReshuffling() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = CloudMachinePinStore(defaults: defaults, scopeProvider: { "team:one" })
        store.reconcile(machineIDs: ["b", "a", "c"])
        store.setPinned(true, machineID: "c")
        store.reconcile(machineIDs: ["new", "a", "c", "b"])
        #expect(store.orderedMachineIDs(["new", "a", "c", "b"]) == ["c", "b", "a", "new"])
        let restored = CloudMachinePinStore(defaults: defaults, scopeProvider: { "team:one" })
        #expect(restored.orderedMachineIDs(["new", "b", "c", "a"]) == ["c", "b", "a", "new"])
        restored.setPinned(false, machineID: "c")
        restored.reconcile(machineIDs: ["newer", "new", "a", "b", "c"])
        #expect(restored.orderedMachineIDs(["newer", "new", "a", "b", "c"]) == ["c", "b", "a", "new", "newer"])
    }

    @Test func manualMovesStayWithinPinTiersAndPersistByIdentity() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = CloudMachinePinStore(defaults: defaults, scopeProvider: { "team:one" })
        store.reconcile(machineIDs: ["p1", "p2", "u1", "u2"])
        store.setPinned(true, machineID: "p1")
        store.setPinned(true, machineID: "p2")

        #expect(store.move(.before("p1"), machineID: "p2", machineIDs: ["p1", "p2", "u1", "u2"]))
        #expect(store.move(.after("u2"), machineID: "u1", machineIDs: ["p1", "p2", "u1", "u2"]))
        #expect(store.orderedMachineIDs(["u1", "p1", "u2", "p2"]) == ["p2", "p1", "u2", "u1"])
        #expect(!store.move(.after("u1"), machineID: "p1", machineIDs: ["p1", "p2", "u1", "u2"]))
        #expect(store.orderedMachineIDs(["p1", "p2", "u1", "u2"]) == ["p2", "p1", "u2", "u1"])

        let restored = CloudMachinePinStore(defaults: defaults, scopeProvider: { "team:one" })
        #expect(restored.orderedMachineIDs(["u2", "p1", "u1", "p2"]) == ["p2", "p1", "u2", "u1"])
        #expect(restored.pinnedMachineIDs == ["p1", "p2"])
    }

    @Test func manualMovesRejectStaleOrSelfTargetsWithoutChangingState() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = CloudMachinePinStore(defaults: defaults, scopeProvider: { "team:one" })
        store.reconcile(machineIDs: ["a", "b", "c"])
        #expect(!store.move(.before("missing"), machineID: "b", machineIDs: ["a", "b", "c"]))
        #expect(!store.move(.after("b"), machineID: "b", machineIDs: ["a", "b", "c"]))
        #expect(store.orderedMachineIDs(["c", "b", "a"]) == ["a", "b", "c"])
    }

    @Test func movingPartialFleetPreservesHiddenOrderAndReconcilesDeletion() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = CloudMachinePinStore(defaults: defaults, scopeProvider: { "team:one" })
        let ids = ["a", "hidden-1", "b", "hidden-2", "c"]
        store.reconcile(machineIDs: ids)
        #expect(store.move(.before("a"), machineID: "c", machineIDs: ["a", "b", "c"]))
        store.remember(machineIDs: ["new", "b"])
        #expect(store.orderedMachineIDs(["new"] + ids.reversed()) == ["c", "a", "hidden-1", "b", "hidden-2", "new"])
        store.setPinned(true, machineID: "hidden-1")
        store.reconcile(machineIDs: ["new", "b", "a", "c", "hidden-2"])
        #expect(store.pinnedMachineIDs.isEmpty)
        let restored = CloudMachinePinStore(defaults: defaults, scopeProvider: { "team:one" })
        #expect(restored.orderedMachineIDs(["new", "hidden-2", "c", "a", "b"]) == ["c", "a", "b", "hidden-2", "new"])
        #expect(!restored.move(.before("hidden-1"), machineID: "b", machineIDs: ["a", "b"]))
        #expect(!restored.move(.before("b"), machineID: "c", machineIDs: ["a", "b"]))
    }

    @Test func pinTransitionsKeepTheChosenOrderAtTheBoundary() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = CloudMachinePinStore(defaults: defaults, scopeProvider: { "team:one" })
        let ids = ["a", "b", "c", "d", "e"]
        store.reconcile(machineIDs: ids)
        store.setPinned(true, machineID: "c")
        store.setPinned(true, machineID: "b")
        #expect(store.move(.up, machineID: "b", machineIDs: ids))
        #expect(store.move(.top, machineID: "e", machineIDs: ids))
        #expect(store.orderedMachineIDs(ids) == ["b", "c", "e", "a", "d"])
        store.setPinned(true, machineID: "d")
        #expect(store.orderedMachineIDs(ids) == ["b", "c", "d", "e", "a"])
        store.setPinned(false, machineID: "b")
        #expect(store.orderedMachineIDs(ids) == ["c", "d", "b", "e", "a"])
        #expect(store.move(.down, machineID: "c", machineIDs: ids))
        #expect(store.orderedMachineIDs(ids) == ["d", "c", "b", "e", "a"])
        #expect(store.pinnedMachineIDs == ["c", "d"])
    }

    @Test func hoverAndNoOpMovesDoNotWriteAndScopeSwitchesDoNotLeak() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let scope = Scope()
        let store = CloudMachinePinStore(defaults: defaults, scopeProvider: { scope.value })
        let ids = ["a", "b", "c"]
        store.reconcile(machineIDs: ids)
        let before = defaults.data(forKey: CloudMachinePinStore.defaultsKey)
        #expect(store.canMove(.before("a"), machineID: "c", machineIDs: ids))
        #expect(!store.move(.before("b"), machineID: "a", machineIDs: ids))
        #expect(defaults.data(forKey: CloudMachinePinStore.defaultsKey) == before)
        #expect(store.move(.top, machineID: "c", machineIDs: ids))
        scope.value = "user:b|team:one"
        #expect(!store.canMove(.down, machineID: "c", machineIDs: ids))
        store.refreshScope()
        store.reconcile(machineIDs: ids)
        #expect(store.orderedMachineIDs(ids) == ids)
        #expect(store.move(.down, machineID: "a", machineIDs: ids))
        scope.value = "user:a|team:one"
        store.refreshScope()
        #expect(store.orderedMachineIDs(ids) == ["c", "a", "b"])
        scope.value = nil
        #expect(!store.move(.top, machineID: "b", machineIDs: ids))
        #expect(store.orderedMachineIDs(ids) == ids)
    }

    /// Pins remain independent of any legacy default-machine preference.
    @Test func pinsIgnoreLegacyDefaultMachinePreference() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("quick", forKey: "cloud.defaultMachineID")
        let store = CloudMachinePinStore(defaults: defaults, scopeProvider: { "team:one" })
        #expect(defaults.object(forKey: "cloud.defaultMachineID") == nil)
        #expect(store.pinnedMachineIDs.isEmpty)
        store.reconcile(machineIDs: ["quick", "other"])
        store.setPinned(true, machineID: "other")
        #expect(store.orderedMachineIDs(["quick", "other"]) == ["other", "quick"])
        #expect(!store.isPinned("quick"))
        #expect(defaults.object(forKey: "cloud.defaultMachineID") == nil)
    }

    /// A machine keeps its pin while it still has a row anywhere (fleet or
    /// catalog); only an identity absent from the complete visible set is pruned.
    @Test func reconcilePrunesOnlyIdentitiesAbsentFromTheVisibleSet() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = CloudMachinePinStore(defaults: defaults, scopeProvider: { "team:one" })
        store.remember(machineIDs: ["fleet", "catalog-only"])
        store.setPinned(true, machineID: "catalog-only")
        store.reconcile(machineIDs: ["fleet", "catalog-only"])
        #expect(store.isPinned("catalog-only"))
        store.reconcile(machineIDs: ["fleet"])
        #expect(!store.isPinned("catalog-only"))
        #expect(store.orderedMachineIDs(["fleet", "catalog-only"]) == ["fleet", "catalog-only"])
        let restored = CloudMachinePinStore(defaults: defaults, scopeProvider: { "team:one" })
        #expect(restored.pinnedMachineIDs.isEmpty)
        store.remember(machineIDs: ["catalog-only"])
        #expect(store.orderedMachineIDs(["catalog-only", "fleet"]) == ["fleet", "catalog-only"])
    }

    @Test func signedOutStoreAppliesAndPersistsNothing() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = CloudMachinePinStore(defaults: defaults, scopeProvider: { nil })
        store.remember(machineIDs: ["a"])
        store.setPinned(true, machineID: "a")
        #expect(!store.isPinned("a"))
        #expect(store.orderedMachineIDs(["b", "a"]) == ["b", "a"])
        #expect(defaults.data(forKey: CloudMachinePinStore.defaultsKey) == nil)
    }

    @Test func orderingHandlesALargeFleetWithoutLosingOrDuplicatingMachines() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = CloudMachinePinStore(defaults: defaults, scopeProvider: { "team:one" })
        let ids = (0..<5_000).map { "machine-\($0)" }
        let pinned = ids.filter { $0.hasSuffix("00") }
        store.reconcile(machineIDs: ids)
        for id in pinned { store.setPinned(true, machineID: id) }
        let ordered = store.orderedMachineIDs(ids.reversed())
        #expect(ordered.count == ids.count)
        #expect(Set(ordered).count == ids.count)
        #expect(Array(ordered.prefix(pinned.count)) == pinned)
        #expect(Array(ordered.dropFirst(pinned.count)) == ids.filter { !$0.hasSuffix("00") })
    }
}
