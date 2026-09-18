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

    @Test func directoryMacAppearsBeforeAuthenticatedPairing() async throws {
        let endpointID = String(repeating: "a", count: 64)
        let route = try CmxAttachRoute(
            id: "iroh-directory-mac",
            kind: .iroh,
            endpoint: .peer(
                identity: CmxIrohPeerIdentity(endpointID: endpointID),
                pathHints: []
            ),
            priority: -10_000
        )
        let candidate = MobileDiscoveredIrohMac(
            deviceID: "directory-mac",
            displayName: "Office Mac",
            instanceTag: "stable",
            routes: [route],
            lastSeenAt: Date(timeIntervalSince1970: 30)
        )
        let store = await shellStore(
            pairedMacs: [],
            discovery: StaticIrohDiscovery(candidates: [candidate])
        )

        await store.refreshDirectoryCandidates()
        let snapshots = MacComputerSnapshot.snapshots(from: store)

        #expect(snapshots.count == 1)
        #expect(snapshots[0].isDirectoryOnly)
        #expect(snapshots[0].title == "Office Mac")
        #expect(snapshots[0].id == MobilePairedMac.pairingID(
            macDeviceID: "directory-mac",
            instanceTag: "stable"
        ))
    }

    private func shellStore(
        pairedMacs: [MobilePairedMac],
        discovery: (any MobileIrohMacDiscovering)? = nil
    ) async -> CMUXMobileShellStore {
        let suiteName = "MacComputerSnapshotBuildScopeTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        let store = MobileShellComposite(
            isSignedIn: true,
            pairedMacStore: WorkspaceMacSelectionPairedMacStore(pairedMacs),
            clientIDRepository: MobileClientIDRepository(defaults: defaults),
            identityProvider: WorkspaceMacSelectionIdentityProvider(userID: "user-1"),
            teamIDProvider: { "team-a" },
            personalIrohDiscovery: discovery,
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

@MainActor
private final class StaticIrohDiscovery: MobileIrohMacDiscovering {
    let candidates: [MobileDiscoveredIrohMac]

    init(candidates: [MobileDiscoveredIrohMac]) {
        self.candidates = candidates
    }

    func discoverLiveMacs() async -> [MobileDiscoveredIrohMac] {
        candidates
    }

    func invalidateDiscovery(forMacDeviceID _: String) async {}
}
