import CMUXMobileCore
import CmuxMobilePairedMac
@testable import CmuxMobileShell
import CmuxMobileShellModel
import Foundation
import Testing
@testable import CmuxMobileShellUI

@MainActor
@Suite struct MacComputerSnapshotBuildScopeTests {
    @Test func computerSnapshotsApplyBuildTagSuffixIdempotently() async {
        let store = await shellStore(pairedMacs: [
            pairedMac(id: "mac-base", name: "MacBook Pro", lastSeenAt: 20),
            pairedMac(id: "mac-tagged", name: "Mac mini (future-one)", lastSeenAt: 10),
        ])

        let snapshots = MacComputerSnapshot.snapshots(from: store, instanceTag: "future-one")
        let titlesByDeviceID = Dictionary(uniqueKeysWithValues: snapshots.map { ($0.deviceId, $0.title) })

        #expect(titlesByDeviceID == [
            "mac-base": "MacBook Pro (future-one)",
            "mac-tagged": "Mac mini (future-one)",
        ])
    }

    @Test func computerSnapshotUsesTheLiveAliasColor() async throws {
        let sharedRoute = try CmxAttachRoute(
            id: "shared-route",
            kind: .tailscale,
            endpoint: .hostPort(host: "100.82.214.112", port: 50922)
        )
        let store = await shellStore(pairedMacs: [
            pairedMac(
                id: "mac-old",
                name: "MacBook Pro",
                lastSeenAt: 20,
                isActive: true,
                routes: [sharedRoute]
            ),
            pairedMac(
                id: "mac-fresh",
                name: "MacBook Pro",
                lastSeenAt: 10,
                routes: [sharedRoute]
            ),
        ])
        let oldPairingID = MobilePairedMac.pairingID(macDeviceID: "mac-old", instanceTag: nil)
        let freshPairingID = MobilePairedMac.pairingID(macDeviceID: "mac-fresh", instanceTag: nil)
        #expect(store.displayPairedMacs.first?.id == oldPairingID)

        func state(for macDeviceID: String) -> MacWorkspaceState {
            MacWorkspaceState(
                macDeviceID: macDeviceID,
                workspaces: [MobileWorkspacePreview(
                    id: MobileWorkspacePreview.ID(rawValue: "workspace-\(macDeviceID)"),
                    macDeviceID: macDeviceID,
                    name: macDeviceID,
                    terminals: []
                )],
                status: .connected
            )
        }

        // Keep the old alias in the additive-only slot table, then simulate the
        // re-paired Mac's live workspace state moving to the fresh alias.
        store.setWorkspaceStatesForTesting([
            oldPairingID: state(for: "mac-old"),
            freshPairingID: state(for: "mac-fresh"),
        ], foregroundMacDeviceID: "mac-old")
        let oldColor = try #require(store.machineColorIndex[oldPairingID])
        let freshColor = try #require(store.machineColorIndex[freshPairingID])
        #expect(oldColor != freshColor)

        store.setWorkspaceStatesForTesting([
            freshPairingID: state(for: "mac-fresh"),
        ], foregroundMacDeviceID: "mac-fresh")
        let workspaceColor = try #require(store.workspaces.first?.machineColorIndex)
        let snapshot = try #require(MacComputerSnapshot.snapshots(from: store).first)

        #expect(workspaceColor == freshColor)
        #expect(snapshot.colorIndex == workspaceColor)
    }

    private func shellStore(pairedMacs: [MobilePairedMac]) async -> CMUXMobileShellStore {
        let suiteName = "MacComputerSnapshotBuildScopeTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        let store = MobileShellComposite(
            isSignedIn: true,
            pairedMacStore: WorkspaceMacSelectionPairedMacStore(pairedMacs),
            clientIDRepository: MobileClientIDRepository(defaults: defaults),
            identityProvider: WorkspaceMacSelectionIdentityProvider(userID: "user-1"),
            teamIDProvider: { "team-a" },
            pairingHintDefaults: defaults,
            multiMacAggregationDefaults: defaults
        )
        await store.loadPairedMacs()
        return store
    }

    private func pairedMac(
        id: String,
        name: String,
        lastSeenAt: TimeInterval,
        isActive: Bool = false,
        routes: [CmxAttachRoute] = []
    ) -> MobilePairedMac {
        MobilePairedMac(
            macDeviceID: id,
            displayName: name,
            routes: routes,
            createdAt: Date(timeIntervalSince1970: 0),
            lastSeenAt: Date(timeIntervalSince1970: lastSeenAt),
            isActive: isActive,
            stackUserID: "user-1",
            teamID: "team-a"
        )
    }
}
