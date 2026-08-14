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

    private func pairedMac(id: String, name: String, lastSeenAt: TimeInterval) -> MobilePairedMac {
        MobilePairedMac(
            macDeviceID: id,
            displayName: name,
            routes: [],
            createdAt: Date(timeIntervalSince1970: 0),
            lastSeenAt: Date(timeIntervalSince1970: lastSeenAt),
            isActive: false,
            stackUserID: "user-1",
            teamID: "team-a"
        )
    }
}
