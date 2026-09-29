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

    @Test
    func loadAllReturnsOnlyTheCurrentAccountAndTeamScope() {
        let defaults = UserDefaults(suiteName: "cmux.snapshot-tests." + UUID().uuidString)!
        let store = MobileWorkspaceSnapshotStore(defaults: defaults)
        let nightly = MacPairingKey(macDeviceID: "mac-a", instanceTag: "nightly")
        let stable = MacPairingKey(macDeviceID: "mac-a", instanceTag: "stable")
        let other = MacPairingKey(macDeviceID: "mac-b", instanceTag: "nightly")

        func state(for pairing: MacPairingKey) -> MacWorkspaceState {
            MacWorkspaceState(
                macDeviceID: pairing.canonicalMacDeviceID,
                instanceTag: pairing.normalizedInstanceTag,
                workspaces: [MobileWorkspacePreview(
                    id: .init(rawValue: pairing.pairingID + "-workspace"),
                    macDeviceID: pairing.canonicalMacDeviceID,
                    name: pairing.pairingID,
                    terminals: []
                )],
                status: .connected,
                workspaceSnapshotIsAuthoritative: true
            )
        }

        store.save(state: state(for: nightly), userID: "user-a", teamID: "team-a", pairing: nightly)
        store.save(state: state(for: stable), userID: "user-a", teamID: "team-a", pairing: stable)
        store.save(state: state(for: other), userID: "user-b", teamID: "team-a", pairing: other)

        let loaded = store.loadAll(userID: "user-a", teamID: "team-a")
        #expect(Set(loaded.map(\.0)) == [nightly, stable])
        #expect(loaded.allSatisfy { $0.1.status == .reconnecting })
        #expect(store.loadAll(userID: "user-a", teamID: "team-b").isEmpty)
    }
}
