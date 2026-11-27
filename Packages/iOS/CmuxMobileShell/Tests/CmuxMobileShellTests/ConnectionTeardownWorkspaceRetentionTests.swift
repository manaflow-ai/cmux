import CmuxMobileShellModel
import Foundation
import Testing
@testable import CmuxMobileShell

/// A transport teardown must retain the last-known workspace snapshot. The
/// snapshot is the user's context while recovery is in flight, and a later
/// healthy list or an explicit hide/unpair operation is the only authority
/// allowed to remove rows.
@MainActor
struct ConnectionTeardownWorkspaceRetentionTests {
    private static let foregroundKey = MacPairingKey(
        macDeviceID: "mac-fg",
        instanceTag: "default"
    )
    private static let secondaryKey = MacPairingKey(
        macDeviceID: "mac-2nd",
        instanceTag: "default"
    )

    private func makeTwoMacStore() -> MobileShellComposite {
        let store = MobileShellComposite(
            isSignedIn: true,
            connectionState: .connected,
            presence: IdlePresence(),
            identityProvider: StaticIdentityProvider(userID: "user-1"),
            teamIDProvider: { "team-1" },
            reachability: AlwaysOnlineReachability(),
            pendingDismissQueue: PendingNotificationDismissQueue(
                defaults: UserDefaults(
                    suiteName: "teardown-retention-\(UUID().uuidString)"
                )!
            )
        )
        var foregroundWorkspace = MobileWorkspacePreview(
            id: "ws-fg",
            macDeviceID: "mac-fg",
            name: "Foreground Workspace",
            terminals: []
        )
        foregroundWorkspace.macInstanceTag = "default"
        var secondaryWorkspace = MobileWorkspacePreview(
            id: "ws-2nd",
            macDeviceID: "mac-2nd",
            name: "Secondary Workspace",
            terminals: []
        )
        secondaryWorkspace.macInstanceTag = "default"
        store.foregroundMacDeviceID = "mac-fg"
        store.activeMacInstanceTag = "default"
        store.macConnectionStatus = .connected
        store.workspacesByMac = [
            Self.foregroundKey: MacWorkspaceState(
                macDeviceID: "mac-fg",
                instanceTag: "default",
                displayName: "Foreground Mac",
                workspaces: [foregroundWorkspace],
                status: .connected
            ),
            Self.secondaryKey: MacWorkspaceState(
                macDeviceID: "mac-2nd",
                instanceTag: "default",
                displayName: "Secondary Mac",
                workspaces: [secondaryWorkspace],
                status: .connected
            ),
        ]
        return store
    }

    @Test func repeatedRecoveryTeardownRetainsRowsAndSelection() {
        let store = makeTwoMacStore()
        let initialRowIDs = Set(store.workspaces.map(\.id))
        let selected = store.workspaces.first { $0.macDeviceID == "mac-fg" }
        #expect(initialRowIDs.count == 2)
        #expect(selected != nil)
        store.selectedWorkspaceID = selected?.id

        store.connectionState = .disconnected
        store.macConnectionStatus = .unavailable
        store.clearRemoteConnectionContext()
        store.clearRemoteConnectionContext()

        #expect(store.workspacesByMac[Self.foregroundKey] != nil)
        #expect(store.workspacesByMac[Self.secondaryKey] != nil)
        #expect(store.workspacesByMac.values.allSatisfy { $0.status == .unavailable })
        #expect(store.selectedWorkspaceID == selected?.id)
        #expect(Set(store.workspaces.map(\.id)) == initialRowIDs)
    }

    @Test func preservingTeardownDowngradesOnlyForegroundEntry() {
        let store = makeTwoMacStore()

        store.connectionState = .disconnected
        store.macConnectionStatus = .unavailable
        store.clearRemoteConnectionContext(preservingOtherMacWorkspaceState: true)

        #expect(store.workspacesByMac[Self.foregroundKey]?.status == .unavailable)
        #expect(store.workspacesByMac[Self.secondaryKey]?.status == .connected)
    }
}
