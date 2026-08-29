import CMUXMobileCore
import Foundation
import Testing

@testable import CmuxMobileShellModel

/// Behavior tests for ``MobileWorkspaceLastTabStore`` using a suite-scoped
/// `UserDefaults` so they never touch `UserDefaults.standard`.
///
/// The store's contract: the tab a workspace last showed on this device is
/// device-local memory, persisted immediately, bounded by dropping the least
/// recently updated workspaces, and keyed by the owner-scoped
/// ``MobileWorkspacePreview/lastTabStateID`` so it survives the aggregate
/// list flipping between plain and Mac-scoped row ids.
@Suite struct MobileWorkspaceLastTabStoreTests {
    private func makeDefaults() -> UserDefaults {
        let suite = "MobileWorkspaceLastTabStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    @Test func roundTripsThroughInjectedDefaults() {
        let defaults = makeDefaults()
        var store = MobileWorkspaceLastTabStore(defaults: defaults)
        store.set(MobileWorkspaceLastTab(kind: .terminal, tabID: "t-2"), for: "ws-a")
        store.set(MobileWorkspaceLastTab(kind: .macSurface, tabID: "s-1"), for: "ws-b")

        let reloaded = MobileWorkspaceLastTabStore(defaults: defaults)
        #expect(reloaded.lastTab(for: "ws-a") == MobileWorkspaceLastTab(kind: .terminal, tabID: "t-2"))
        #expect(reloaded.lastTab(for: "ws-b") == MobileWorkspaceLastTab(kind: .macSurface, tabID: "s-1"))
        #expect(reloaded.lastTab(for: "ws-c") == nil)
    }

    @Test func inMemoryStoreDoesNotPersist() {
        var store = MobileWorkspaceLastTabStore.inMemory
        store.set(MobileWorkspaceLastTab(kind: .terminal, tabID: "t-1"), for: "ws-a")
        #expect(store.lastTab(for: "ws-a") == MobileWorkspaceLastTab(kind: .terminal, tabID: "t-1"))
        #expect(MobileWorkspaceLastTabStore.inMemory.lastTab(for: "ws-a") == nil)
    }

    @Test func reRecordingTheUnchangedTabDoesNotRewriteDefaults() {
        let defaults = makeDefaults()
        var store = MobileWorkspaceLastTabStore(defaults: defaults)
        store.set(MobileWorkspaceLastTab(kind: .terminal, tabID: "t-1"), for: "ws-a")
        let persisted = defaults.data(forKey: MobileWorkspaceLastTabStore.defaultsKey)
        #expect(persisted != nil)

        // The synchronizer re-records the displayed tab on every workspace
        // list refresh; an unchanged tab must be a no-op write.
        defaults.removeObject(forKey: MobileWorkspaceLastTabStore.defaultsKey)
        store.set(MobileWorkspaceLastTab(kind: .terminal, tabID: "t-1"), for: "ws-a")
        #expect(defaults.data(forKey: MobileWorkspaceLastTabStore.defaultsKey) == nil)
    }

    @Test func prunesLeastRecentlyUpdatedWorkspacesBeyondCap() {
        var store = MobileWorkspaceLastTabStore.inMemory
        let overflow = 10
        for index in 0..<(MobileWorkspaceLastTabStore.maxEntries + overflow) {
            store.set(MobileWorkspaceLastTab(kind: .terminal, tabID: "t-\(index)"), for: "ws-\(index)")
        }
        for index in 0..<overflow {
            #expect(store.lastTab(for: "ws-\(index)") == nil)
        }
        #expect(store.lastTab(for: "ws-\(overflow)") != nil)
        #expect(store.lastTab(for: "ws-\(MobileWorkspaceLastTabStore.maxEntries + overflow - 1)") != nil)
    }

    @Test func lastTabStateIDIsPlainForAnonymousWorkspaces() {
        let workspace = MobileWorkspacePreview(
            id: "workspace-1",
            name: "Plain",
            terminals: []
        )
        #expect(workspace.lastTabStateID == "workspace-1")
    }

    @Test func lastTabStateIDIsStableAcrossAggregateRowScoping() {
        // Single-Mac list: the row id is the Mac-local id.
        let plainRow = MobileWorkspacePreview(
            id: "workspace-1",
            macDeviceID: "mac-a",
            name: "Same workspace",
            terminals: []
        )
        // Multi-Mac aggregate: the row id is owner-scoped and the Mac-local id
        // moves to `remoteWorkspaceID`.
        var scopedRow = MobileWorkspacePreview(
            id: MobileWorkspaceAggregation().rowID(
                macDeviceID: "mac-a",
                workspaceID: "workspace-1"
            ),
            macDeviceID: "mac-a",
            name: "Same workspace",
            terminals: []
        )
        scopedRow.remoteWorkspaceID = "workspace-1"

        #expect(plainRow.lastTabStateID == scopedRow.lastTabStateID)
        let expectedOwner = CmxMacAppInstanceIdentity(macDeviceID: "mac-a", instanceTag: nil).id
        #expect(plainRow.lastTabStateID == "\(expectedOwner)\u{1F}workspace-1")
    }

    @Test func lastTabStateIDDistinguishesMacsSharingWorkspaceIDs() {
        let onMacA = MobileWorkspacePreview(
            id: "workspace-1", macDeviceID: "mac-a", name: "A", terminals: []
        )
        let onMacB = MobileWorkspacePreview(
            id: "workspace-1", macDeviceID: "mac-b", name: "B", terminals: []
        )
        #expect(onMacA.lastTabStateID != onMacB.lastTabStateID)
    }
}
