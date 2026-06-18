import Testing
@testable import CmuxMobileShellUI

/// Tests the pure expansion-state codec the device tree persists via
/// `@AppStorage`, so the device → tag open/closed shape survives relaunch.
@Suite struct DeviceTreeExpansionStoreTests {
    @Test func roundTripsThroughStorageString() {
        var store = DeviceTreeExpansionStore()
        store.setExpanded("device:a", true)
        store.setExpanded("instance:a:stable", true)
        let restored = DeviceTreeExpansionStore(storage: store.storage)
        #expect(restored.isExpanded("device:a"))
        #expect(restored.isExpanded("instance:a:stable"))
        #expect(!restored.isExpanded("device:b"))
    }

    @Test func collapsingRemovesFromStorage() {
        var store = DeviceTreeExpansionStore(expandedIDs: ["device:a", "device:b"])
        store.setExpanded("device:a", false)
        #expect(!store.isExpanded("device:a"))
        #expect(store.isExpanded("device:b"))
        // Stable, sorted serialization so equal sets always encode identically.
        #expect(store.storage == "device:b")
    }

    @Test func blankStorageDecodesToNoExpansion() {
        #expect(DeviceTreeExpansionStore(storage: "").expandedIDs.isEmpty)
        #expect(DeviceTreeExpansionStore(storage: "\n  \n").expandedIDs.isEmpty)
    }
}
