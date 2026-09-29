import CmuxMobileShell
import CmuxMobileShellModel
import Foundation
import Testing

@MainActor
struct MobileWorkspaceSnapshotStoreTests {
    @Test
    func snapshotsRoundTripWithoutAuthorityOrTerminalOutput() {
        let defaults = UserDefaults(suiteName: "cmux.snapshot-tests.\(UUID().uuidString)")!
        let store = MobileWorkspaceSnapshotStore(defaults: defaults)
        let pairing = MacPairingKey(macDeviceID: "mac-a", instanceTag: "nightly")
        let workspace = MobileWorkspacePreview(
            id: "workspace-a",
            macDeviceID: "mac-a",
            name: "Mario",
            terminals: [MobileTerminalPreview(id: "terminal-a", name: "codex")]
        )
        let state = MacWorkspaceState(
            macDeviceID: "mac-a",
            instanceTag: "nightly",
            displayName: "Build Mac",
            workspaces: [workspace],
            status: .connected,
            workspaceSnapshotIsAuthoritative: true,
            actionCapabilities: MobileWorkspaceActionCapabilities(
                supportsWorkspaceActions: true,
                supportsWorkspaceMetadata: true
            )
        )

        store.save(state: state, userID: "user-a", teamID: "team-a", pairing: pairing)
        let restored = store.load(userID: "user-a", teamID: "team-a", pairing: pairing)

        #expect(restored?.workspaces == [workspace])
        #expect(restored?.status == .reconnecting)
        #expect(restored?.workspaceSnapshotIsAuthoritative == false)
        #expect(restored?.actionCapabilities == MobileWorkspaceActionCapabilities.none)
        #expect(store.load(userID: "user-b", teamID: "team-a", pairing: pairing) == nil)
        #expect(store.load(userID: "user-a", teamID: "team-b", pairing: pairing) == nil)
    }
}
