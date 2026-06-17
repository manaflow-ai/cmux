import CMUXMobileCore
import CmuxMobilePairedMac
import CmuxMobileShellModel
import Foundation
import Testing
@testable import CmuxMobileShell

/// Behavior tests for the P2 (unified list UI) store seams: scoped selection
/// round-trips through the bare authoritative selection, and the per-row Mac
/// chip name map resolves from registry/paired/live sources.
@MainActor
@Suite struct UnifiedListSelectionTests {
    private func pairedMac(_ deviceID: String, name: String?) -> MobilePairedMac {
        MobilePairedMac(
            macDeviceID: deviceID,
            displayName: name,
            routes: [],
            createdAt: Date(timeIntervalSince1970: 0),
            lastSeenAt: Date(timeIntervalSince1970: 0),
            isActive: false,
            stackUserID: nil
        )
    }

    private func registryDevice(_ deviceID: String, name: String?) -> RegistryDevice {
        RegistryDevice(
            deviceId: deviceID,
            platform: "mac",
            displayName: name,
            lastSeenAt: Date(timeIntervalSince1970: 0),
            instances: []
        )
    }

    @Test func scopedSelectionCarriesActiveDeviceIDAndWritesBareID() {
        let store = MobileShellComposite.preview(unifiedMultiMacEnabled: true)
        store.debugSetActiveDeviceID("mac-active")

        store.scopedSelectedWorkspaceID = ScopedWorkspaceID(deviceId: "mac-active", workspaceID: "ws-1")

        // The store's authoritative selection stays the bare wire id.
        #expect(store.selectedWorkspaceID == "ws-1")
        // Reading back re-scopes with the active device id.
        #expect(store.scopedSelectedWorkspaceID == ScopedWorkspaceID(deviceId: "mac-active", workspaceID: "ws-1"))
    }

    @Test func scopedSelectionNilClearsBareSelection() {
        let store = MobileShellComposite.preview(unifiedMultiMacEnabled: true)
        store.debugSetActiveDeviceID("mac-active")
        store.scopedSelectedWorkspaceID = ScopedWorkspaceID(workspaceID: "ws-1")
        #expect(store.selectedWorkspaceID != nil)

        store.scopedSelectedWorkspaceID = nil
        #expect(store.selectedWorkspaceID == nil)
        #expect(store.scopedSelectedWorkspaceID == nil)
    }

    @Test func nilActiveDeviceYieldsUnscopedSelection() {
        let store = MobileShellComposite.preview(unifiedMultiMacEnabled: true)
        // No active device id (manual ticket / preview): selection is unscoped.
        store.scopedSelectedWorkspaceID = ScopedWorkspaceID(workspaceID: "ws-1")
        #expect(store.scopedSelectedWorkspaceID == ScopedWorkspaceID(deviceId: "", workspaceID: "ws-1"))
    }

    @Test func deviceNamesResolveActiveHostOverPairedAndRegistry() {
        let store = MobileShellComposite.preview(unifiedMultiMacEnabled: true)
        store.debugSetActiveDeviceID("mac-active")
        store.debugSetConnectedHostName("Live Studio")
        // The active Mac also appears (staler) in the registry and paired list;
        // the live connected host name must win for the active device.
        store.debugSetRegistryDevices([
            registryDevice("mac-active", name: "Registry Studio"),
            registryDevice("mac-2", name: "Registry Two"),
        ])
        store.debugSetPairedMacs([
            pairedMac("mac-active", name: "Paired Studio"),
            pairedMac("mac-3", name: "Paired Three"),
        ])

        let names = store.unifiedDeviceNames
        #expect(names["mac-active"] == "Live Studio")
        #expect(names["mac-2"] == "Registry Two")
        #expect(names["mac-3"] == "Paired Three")
    }

    @Test func deviceNamesSkipEmptyAndUnknown() {
        let store = MobileShellComposite.preview(unifiedMultiMacEnabled: true)
        store.debugSetActiveDeviceID("mac-active")
        // A blank live host name must not shadow a better source for the active
        // device; an empty device id is never recorded.
        store.debugSetConnectedHostName("   ")
        store.debugSetRegistryDevices([registryDevice("mac-active", name: "Registry Studio")])
        store.debugSetPairedMacs([pairedMac("", name: "No Device")])

        let names = store.unifiedDeviceNames
        #expect(names["mac-active"] == "Registry Studio")
        #expect(names[""] == nil)
    }
}
