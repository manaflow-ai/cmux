import CMUXMobileCore
import CmuxMobilePairedMac
import Foundation
import Testing
@testable import CmuxMobileShell

@MainActor
private final class RecoveryForgetStub: MobileIrohMacForgetting {
    private(set) var forgottenIDs: [String] = []

    func forgetComputer(
        macDeviceID: String,
        instanceTag _: String?,
        expectedAccountID _: String
    ) async throws {
        forgottenIDs.append(macDeviceID)
    }
}

@MainActor
private final class RecoveryDirectoryStub: MobileIrohMacDiscovering {
    var candidates: [MobileDiscoveredIrohMac]
    private(set) var invalidatedIDs: [String] = []

    init(candidates: [MobileDiscoveredIrohMac]) {
        self.candidates = candidates
    }

    func discoverLiveMacs() async -> [MobileDiscoveredIrohMac] {
        candidates
    }

    func invalidateDiscovery(forMacDeviceID deviceID: String) async {
        invalidatedIDs.append(deviceID)
    }

    func replaceCandidates(_ candidates: [MobileDiscoveredIrohMac]) {
        self.candidates = candidates
    }
}

@MainActor
@Suite struct MobileShellCompositeForgottenMacRecoveryTests {
    @Test func rehydratesAfterForgetFromAuthenticatedDirectoryAndCoalescesDuplicates() async throws {
        let suiteName = "forgotten-mac-recovery-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let pairedStore = DelayedTeamPairedMacStore(
            recordsByTeam: [
                "team-a": [
                    MobilePairedMac(
                        macDeviceID: "mac-a",
                        displayName: "Desk Mac",
                        routes: [],
                        createdAt: Date(timeIntervalSince1970: 1),
                        lastSeenAt: Date(timeIntervalSince1970: 2),
                        isActive: false,
                        stackUserID: "user-1",
                        teamID: "team-a"
                    ),
                ],
            ],
            blockedTeams: []
        )
        let route = try CmxAttachRoute(
            id: "iroh-recovered",
            kind: .iroh,
            endpoint: .peer(
                identity: CmxIrohPeerIdentity(endpointID: String(repeating: "a", count: 64)),
                pathHints: []
            )
        )
        let recoveredCandidates = [
            MobileDiscoveredIrohMac(
                deviceID: "MAC-A",
                displayName: "Recovered Mac",
                instanceTag: "",
                routes: [route],
                lastSeenAt: Date(timeIntervalSince1970: 10)
            ),
            // Older directory snapshots could contain the same physical id with
            // different casing. The recovery projection must create one row.
            MobileDiscoveredIrohMac(
                deviceID: "mac-a",
                displayName: "Duplicate Mac",
                instanceTag: "",
                routes: [route],
                lastSeenAt: Date(timeIntervalSince1970: 10)
            ),
        ]
        let discovery = RecoveryDirectoryStub(candidates: [])
        let forget = RecoveryForgetStub()
        let shell = MobileShellComposite(
            isSignedIn: true,
            pairedMacStore: pairedStore,
            personalIrohDiscovery: discovery,
            personalIrohForget: forget,
            identityProvider: StaticIdentityProvider(userID: "user-1"),
            teamIDProvider: { "team-a" },
            pairingHintDefaults: defaults,
            hiddenMacStore: InMemoryPairedMacHiddenStore()
        )

        await shell.loadPairedMacs()
        await shell.hideMac(macDeviceID: "mac-a")
        let hidden = try #require(shell.hiddenComputers.first)

        #expect(await shell.forgetHiddenComputer(hidden))
        #expect(forget.forgottenIDs == ["mac-a"])
        #expect(discovery.invalidatedIDs == ["mac-a"])
        let afterForget = try await pairedStore.loadAll(
            stackUserID: "user-1",
            teamID: "team-a"
        )
        #expect(afterForget.isEmpty)

        // The Mac can publish after the revoke's immediate refresh. The
        // directory update path must consume the durable recovery identity.
        discovery.replaceCandidates(recoveredCandidates)
        await shell.recoverForgottenMacsFromDirectory(
            scope: MobileShellScopeSnapshot(
                userID: "user-1",
                teamID: "team-a",
                generation: 0
            ),
            refreshDirectory: false
        )

        let recovered = try await pairedStore.loadAll(
            stackUserID: "user-1",
            teamID: "team-a"
        )
        #expect(recovered.count == 1)
        #expect(recovered.first?.macDeviceID == "mac-a")
        #expect(recovered.first?.displayName == "Recovered Mac")
        #expect(shell.pairedMacs.count == 1)
        #expect(shell.pairedMacs.first?.macDeviceID == "mac-a")
    }

}
