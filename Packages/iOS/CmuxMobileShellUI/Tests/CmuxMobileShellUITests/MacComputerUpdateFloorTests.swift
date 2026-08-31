import CMUXMobileCore
import CmuxMobilePairedMac
@testable import CmuxMobileShell
import CmuxMobileShellModel
import Foundation
import Testing
@testable import CmuxMobileShellUI

/// The Computers surface and the What's New page must tell the pairing-floor
/// story from `MobileMacPairingFloor`: a legacy Tailscale-only pairing gets
/// the row badge, an Iroh-capable one does not, and the release notes carry
/// the requirement as one footnote instead of a feature row.
@MainActor
@Suite struct MacComputerUpdateFloorTests {
    @Test func snapshotFlagsOnlyLegacyTailscalePairings() async throws {
        let legacy = pairedMac(
            id: "mac-legacy",
            name: "Old iMac",
            lastSeenAt: 20,
            routes: [try tailscaleRoute()]
        )
        let updated = pairedMac(
            id: "mac-updated",
            name: "MacBook Pro",
            lastSeenAt: 10,
            routes: [try tailscaleRoute(), try irohRoute()]
        )
        let store = await shellStore(pairedMacs: [legacy, updated])

        let snapshots = MacComputerSnapshot.snapshots(from: store)
        let needsUpdateByDeviceID = Dictionary(
            uniqueKeysWithValues: snapshots.map { ($0.deviceId, $0.needsMacUpdate) }
        )

        #expect(needsUpdateByDeviceID == [
            "mac-legacy": true,
            "mac-updated": false,
        ])
    }

    @Test func whatsNewCarriesTheFloorAsFootnoteNotFeatureRow() throws {
        let page = MobileWhatsNewCatalog.connectionsUpdate

        let footnote = try #require(page.footnote)
        #expect(footnote.contains(MobileMacPairingFloor.requiredMacVersionLabel))
        guard case .features(let features) = page.body else {
            Issue.record("connections update page lost its feature rows")
            return
        }
        #expect(!features.contains { $0.symbol == "exclamationmark.triangle.fill" })
    }

    private func tailscaleRoute() throws -> CmxAttachRoute {
        try CmxAttachRoute(
            id: "tailscale",
            kind: .tailscale,
            endpoint: .hostPort(host: "mac.tailnet.ts.net", port: 52700)
        )
    }

    private func irohRoute() throws -> CmxAttachRoute {
        try CmxAttachRoute(
            id: "iroh",
            kind: .iroh,
            endpoint: .peer(
                identity: CmxIrohPeerIdentity(
                    endpointID: String(repeating: "a", count: 64)
                ),
                pathHints: []
            )
        )
    }

    private func shellStore(pairedMacs: [MobilePairedMac]) async -> CMUXMobileShellStore {
        let suiteName = "MacComputerUpdateFloorTests-\(UUID().uuidString)"
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
        routes: [CmxAttachRoute]
    ) -> MobilePairedMac {
        MobilePairedMac(
            macDeviceID: id,
            displayName: name,
            routes: routes,
            createdAt: Date(timeIntervalSince1970: 0),
            lastSeenAt: Date(timeIntervalSince1970: lastSeenAt),
            isActive: false,
            stackUserID: "user-1",
            teamID: "team-a"
        )
    }
}
