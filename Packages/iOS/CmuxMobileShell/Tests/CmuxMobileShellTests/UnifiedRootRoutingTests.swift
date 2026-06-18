import CMUXMobileCore
import CmuxMobileShellModel
import Foundation
import Testing
@testable import CmuxMobileShell

/// Behavior tests for the root-view routing seams that fix the "signed in but
/// stuck on Add device" bug: ``MobileShellComposite/shouldShowUnifiedWorkspaceList``
/// and ``MobileShellComposite/isDiscoveringUnifiedMacs``.
///
/// The bug: a freshly signed-in phone with a discoverable online Mac dead-ended
/// on the add-device screen because the root view only showed the workspace list
/// when `connectionState == .connected`. These predicates let the unified list
/// render from the registry/aggregator with NO heavy connection, so signing in
/// lands on the list instead of add-device.
@MainActor
@Suite struct UnifiedRootRoutingTests {
    private func makeWorkspace(id: String, deviceId: String = "") -> MobileWorkspacePreview {
        MobileWorkspacePreview(
            id: .init(rawValue: id),
            deviceId: deviceId,
            name: "WS \(id)",
            isPinned: false,
            lastActivityAt: nil,
            terminals: [MobileTerminalPreview(id: .init(rawValue: "\(id)-t"), deviceId: deviceId, name: "T")]
        )
    }

    private func onlineInstance(_ deviceId: String) -> PresenceInstance {
        PresenceInstance(deviceId: deviceId, tag: "default", platform: "mac", online: true, lastSeenAt: 1000)
    }

    /// The core fix: a discovered online Mac contributes a slice through the
    /// aggregator with NO active heavy connection (no `activeDeviceID`, no live
    /// `workspaces`), and that alone makes the unified list show — the state that
    /// previously fell through to the add-device screen.
    @Test func discoveredOnlineMacShowsListWithoutHeavyConnection() {
        let store = MobileShellComposite.preview(unifiedMultiMacEnabled: true)
        // No heavy connection: clear the preview placeholder workspaces and leave
        // activeDeviceID nil.
        store.workspaces = []
        store.debugApplyPresence(.online(onlineInstance("mac-b")))
        store.multiMacAggregator.debugSetSlice(
            deviceID: "mac-b",
            workspaces: [makeWorkspace(id: "ws-b", deviceId: "mac-b")]
        )

        #expect(store.activeDeviceID == nil)
        #expect(!store.unifiedWorkspaces.isEmpty)
        #expect(store.shouldShowUnifiedWorkspaceList)
        // With something to show, the determining spinner must not be requested.
        #expect(!store.isDiscoveringUnifiedMacs)
    }

    /// FLAG OFF parity: even with workspaces present, the unified routing gate is
    /// inert, so routing falls back to the connection-gated path unchanged.
    @Test func flagOffNeverShowsUnifiedListOrSpinner() {
        let store = MobileShellComposite.preview(unifiedMultiMacEnabled: false)
        store.workspaces = [makeWorkspace(id: "live-1")]
        store.debugSetActiveDeviceID("mac-active")

        #expect(!store.shouldShowUnifiedWorkspaceList)
        #expect(!store.isDiscoveringUnifiedMacs)
    }

    /// Flag on but nothing discovered yet (no live workspaces, no online slices):
    /// the list gate is false, so routing relies on the determining spinner /
    /// add-device fallback rather than showing an empty list.
    @Test func emptyDiscoveryDoesNotShowList() {
        let store = MobileShellComposite.preview(unifiedMultiMacEnabled: true)
        store.workspaces = []

        #expect(store.unifiedWorkspaces.isEmpty)
        #expect(!store.shouldShowUnifiedWorkspaceList)
    }

    /// An offline discovered Mac is gated out of the unified list, so it does not
    /// trip the list gate — the same presence rule the merge enforces.
    @Test func offlineDiscoveredMacDoesNotShowList() {
        let store = MobileShellComposite.preview(unifiedMultiMacEnabled: true)
        store.workspaces = []
        store.debugApplyPresence(.offline(
            PresenceInstance(deviceId: "mac-b", tag: "default", platform: "mac", online: false, lastSeenAt: 1000),
            reason: .timeout
        ))
        store.multiMacAggregator.debugSetSlice(
            deviceID: "mac-b",
            workspaces: [makeWorkspace(id: "ws-b", deviceId: "mac-b")]
        )

        #expect(store.unifiedWorkspaces.isEmpty)
        #expect(!store.shouldShowUnifiedWorkspaceList)
    }
}
