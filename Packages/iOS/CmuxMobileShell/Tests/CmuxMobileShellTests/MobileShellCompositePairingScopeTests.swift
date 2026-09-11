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
                    // Sibling builds are distinct processes, so each listens
                    // on its own port; rows sharing one endpoint would be the
                    // same instance and deliberately coalesce.
                    try Self.pairedMac(
                        id: "mac-a",
                        displayName: "Desk Mac",
                        host: "100.82.214.112",
                        port: 50_901,
                        lastSeenAt: Date(timeIntervalSince1970: 20),
                        isActive: true,
                        customColor: "red",
                        instanceTag: "nightly"
                    ),
                    try Self.pairedMac(
                        id: "mac-a",
                        displayName: "Desk Mac",
                        host: "100.82.214.112",
                        port: 50_902,
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

        #expect(customizations[MobilePairedMac.pairingID(
            macDeviceID: "mac-a",
            instanceTag: "nightly"
        )]?.customColor == "red")
        #expect(customizations[MobilePairedMac.pairingID(
            macDeviceID: "mac-a",
            instanceTag: "stable"
        )]?.customColor == "blue")
    }

    @Test func exactPairingConnectionStatusOnlyMatchesConnectedPairing() {
        typealias Status = MobileMacConnectionStatus
        func refine(_ deviceStatus: Status?, connectedTag: String?, rowTag: String?) -> Status? {
            MobileShellComposite.exactPairingConnectionStatus(
                deviceStatus: deviceStatus,
                connectedMacDeviceID: "mac-a",
                connectedMacInstanceTag: connectedTag,
                rowMacDeviceID: "mac-a",
                rowInstanceTag: rowTag
            )
        }

        #expect(refine(.connected, connectedTag: "stable", rowTag: "stable") == .connected)
        #expect(refine(.connected, connectedTag: "stable", rowTag: "nightly") == nil)
        #expect(refine(.connected, connectedTag: nil, rowTag: "nightly") == nil)
        // Legacy and sibling rows cannot borrow the connected build's status.
        #expect(refine(.connected, connectedTag: "stable", rowTag: nil) == nil)
        // A redial targeting one pairing must not mark the sibling build's
        // row; with no known target the device status still passes through.
        #expect(refine(.reconnecting, connectedTag: "stable", rowTag: "nightly") == nil)
        #expect(refine(.reconnecting, connectedTag: "stable", rowTag: "stable") == .reconnecting)
        #expect(refine(.reconnecting, connectedTag: nil, rowTag: "nightly") == .reconnecting)
        #expect(refine(nil, connectedTag: "stable", rowTag: "nightly") == nil)
        // Tagged rows never consume the legacy physical-device fallback.
        #expect(MobileShellComposite.exactPairingConnectionStatus(
            deviceStatus: .connected,
            connectedMacDeviceID: "mac-b",
            connectedMacInstanceTag: "stable",
            rowMacDeviceID: "mac-a",
            rowInstanceTag: "nightly"
        ) == nil)
    }

    @Test func siblingBuildsAreSeparateAggregationCandidates() async throws {
        let pairedStore = DelayedTeamPairedMacStore(
            recordsByTeam: [
                "team-a": [
                    try Self.pairedMac(
                        id: "mac-a",
                        displayName: "Desk Mac",
                        host: "100.82.214.112",
                        port: 50922,
                        lastSeenAt: Date(timeIntervalSince1970: 20),
                        isActive: true,
                        instanceTag: "nightly"
                    ),
                    try Self.pairedMac(
                        id: "mac-a",
                        displayName: "Desk Mac",
                        host: "100.82.214.112",
                        port: 50923,
                        lastSeenAt: Date(timeIntervalSince1970: 10),
                        isActive: false,
                        instanceTag: "default"
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

        let candidates = store.secondaryAggregationCandidateMacs(
            from: store.displayPairedMacs
        )

        // Previously coalescePairedMacsByCanonicalDeviceID collapsed sibling
        // builds to one candidate per physical Mac.
        #expect(candidates.count == 2)
        #expect(Set(candidates.map(\.id)).count == 2)
        #expect(Set(candidates.map(\.macDeviceID)) == ["mac-a"])
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
