import CmuxMobileShellModel
import Foundation
import Testing
@testable import CmuxMobileShell

/// Connection teardown is a transport event: it must never remove user-visible
/// workspace rows, retarget the selection, or change derived row identity.
/// Rows are removed only by authoritative events (a healthy workspace list,
/// unpair/hide, sign-out, team change).
///
/// These pin the reconnect regression where a recovery redial tore down the
/// connection context once (dropping every secondary Mac's rows, which flips
/// multi-Mac row-id scoping and re-keys the pushed navigation route), and a
/// failed first dial tore it down again with the foreground identity already
/// nil — so the retention filter keyed on the anonymous sentinel, wiped
/// `workspacesByMac` entirely, nilled the selection, and popped the mounted
/// workspace detail the moment reconnecting began.
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

    /// Models the recovery sequence exactly: redial teardown with the
    /// foreground identity still set, then a failed-dial teardown after that
    /// identity was nilled by the first.
    private func runRecoveryTeardownTwice(on store: MobileShellComposite) {
        store.connectionState = .disconnected
        store.macConnectionStatus = .unavailable
        store.clearRemoteConnectionContext()
        store.clearRemoteConnectionContext()
    }

    @Test func teardownRetainsEveryMacsRowsAndForegroundSelection() {
        let store = makeTwoMacStore()
        let initialRowIDs = Set(store.workspaces.map(\.id))
        #expect(initialRowIDs.count == 2)
        let selected = store.workspaces.first { $0.macDeviceID == "mac-fg" }
        #expect(selected != nil)
        store.selectedWorkspaceID = selected?.id

        store.connectionState = .disconnected
        store.macConnectionStatus = .unavailable
        store.clearRemoteConnectionContext()

        #expect(store.workspacesByMac[Self.foregroundKey] != nil)
        #expect(store.workspacesByMac[Self.secondaryKey] != nil)
        #expect(store.workspacesByMac.values.allSatisfy { $0.status == .unavailable })
        #expect(store.selectedWorkspaceID == selected?.id)
        #expect(Set(store.workspaces.map(\.id)) == initialRowIDs)

        store.clearRemoteConnectionContext()

        #expect(store.workspacesByMac[Self.foregroundKey] != nil)
        #expect(store.workspacesByMac[Self.secondaryKey] != nil)
        #expect(store.selectedWorkspaceID == selected?.id)
        #expect(Set(store.workspaces.map(\.id)) == initialRowIDs)
    }

    @Test func teardownKeepsSelectionOnSecondaryMacRow() {
        let store = makeTwoMacStore()
        let selected = store.workspaces.first { $0.macDeviceID == "mac-2nd" }
        #expect(selected != nil)
        store.selectedWorkspaceID = selected?.id

        runRecoveryTeardownTwice(on: store)

        #expect(store.workspacesByMac[Self.secondaryKey] != nil)
        #expect(store.selectedWorkspaceID == selected?.id)
        #expect(store.workspaces.contains { $0.id == selected?.id })
    }

    @Test func preservingTeardownStillDowngradesOnlyTheForegroundEntry() {
        let store = makeTwoMacStore()

        store.connectionState = .disconnected
        store.macConnectionStatus = .unavailable
        store.clearRemoteConnectionContext(preservingOtherMacWorkspaceState: true)

        #expect(store.workspacesByMac[Self.foregroundKey]?.status == .unavailable)
        #expect(store.workspacesByMac[Self.secondaryKey]?.status == .connected)
    }
}
