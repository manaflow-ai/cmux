import CMUXMobileCore
import CmuxMobilePairedMac
import CmuxMobileShellModel
import Foundation
import Testing
@testable import CmuxMobileShell

/// Sibling app builds (Nightly + Stable) share one `macDeviceID`. State that is
/// keyed by device id must resolve deterministically to the pairing the phone
/// actually targets instead of whichever sibling happens to iterate last.
@MainActor
@Suite struct MobileShellCompositePairingScopeTests {
    @Test func activePairingCustomizationWinsForSharedDeviceAlias() async throws {
        let pairedStore = DelayedTeamPairedMacStore(
            recordsByTeam: [
                "team-a": [
                    try Self.pairedMac(
                        id: "mac-a",
                        displayName: "Desk Mac",
                        host: "100.82.214.112",
                        lastSeenAt: Date(timeIntervalSince1970: 20),
                        isActive: true,
                        customColor: "red",
                        instanceTag: "nightly"
                    ),
                    try Self.pairedMac(
                        id: "mac-a",
                        displayName: "Desk Mac",
                        host: "100.82.214.112",
                        lastSeenAt: Date(timeIntervalSince1970: 10),
                        isActive: false,
                        customColor: "blue",
                        instanceTag: "stable"
                    ),
                ],
            ],
            blockedTeams: []
        )
        let store = MobileShellComposite(
            isSignedIn: true,
            pairedMacStore: pairedStore,
            identityProvider: StaticIdentityProvider(userID: "user-1"),
            teamIDProvider: { "team-a" },
            hiddenMacStore: InMemoryPairedMacHiddenStore()
        )
        await store.loadPairedMacs()
        #expect(store.displayPairedMacs.count == 2)

        let customizations = store.pairedMacCustomizationsByAliasID()

        // The active pairing represents the device wherever state has no
        // per-build dimension; the sibling must not overwrite it.
        #expect(customizations["mac-a"]?.customColor == "red")
        #expect(customizations["mac-a"]?.instanceTag == "nightly")
    }

    private static func pairedMac(
        id: String,
        displayName: String,
        host: String,
        port: Int = 50922,
        lastSeenAt: Date,
        isActive: Bool,
        customColor: String? = nil,
        instanceTag: String? = nil
    ) throws -> MobilePairedMac {
        MobilePairedMac(
            macDeviceID: id,
            displayName: displayName,
            routes: [try CmxAttachRoute(
                id: "manual",
                kind: .tailscale,
                endpoint: .hostPort(host: host, port: port)
            )],
            createdAt: Date(timeIntervalSince1970: 1),
            lastSeenAt: lastSeenAt,
            isActive: isActive,
            stackUserID: "user-1",
            teamID: "team-a",
            customColor: customColor,
            instanceTag: instanceTag
        )
    }
}
