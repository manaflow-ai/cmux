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

    /// Pins are independent of the Cmd+Y default machine: neither preference
    /// reads, writes, or orders through the other.
    @Test func pinsLeaveTheDefaultMachinePreferenceAlone() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let defaultStore = DefaultCloudMachineStore(defaults: defaults)
        defaultStore.machineID = "quick"
        let store = CloudMachinePinStore(defaults: defaults, scopeProvider: { "team:one" })
        #expect(defaults.string(forKey: DefaultCloudMachineStore.defaultsKey) == "quick")
        #expect(store.pinnedMachineIDs.isEmpty)
        store.reconcile(machineIDs: ["quick", "other"])
        store.setPinned(true, machineID: "other")
        #expect(store.orderedMachineIDs(["quick", "other"]) == ["other", "quick"])
        #expect(!store.isPinned("quick"))
        #expect(DefaultCloudMachineStore(defaults: defaults).machineID == "quick")
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
