import CMUXMobileCore
import Testing
@testable import CmuxMobileShell

/// The pairing floor's route-truth must match the reconnect path's
/// legacy-pairing classification: a Tailscale route without an Iroh identity
/// is the one shape this build refuses to dial until the Mac updates.
@Suite struct MobileMacPairingFloorTests {
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

    @Test func tailscaleOnlyPairingRequiresMacUpdate() throws {
        #expect(MobileMacPairingFloor.pairingRequiresMacUpdate(
            routes: [try tailscaleRoute()]
        ))
    }

    @Test func irohIdentityLiftsTheFloor() throws {
        #expect(!MobileMacPairingFloor.pairingRequiresMacUpdate(
            routes: [try tailscaleRoute(), try irohRoute()]
        ))
        #expect(!MobileMacPairingFloor.pairingRequiresMacUpdate(
            routes: [try irohRoute()]
        ))
    }

    @Test func pairingsWithoutTailscaleRoutesAreNotFlagged() throws {
        // No routes at all (a fresh registry row) and non-Tailscale shapes
        // never claim the Mac needs an update: the floor statement is scoped
        // to the legacy private-network pairing the dialer actually refuses.
        #expect(!MobileMacPairingFloor.pairingRequiresMacUpdate(routes: []))
        let websocket = try CmxAttachRoute(
            id: "ws",
            kind: .websocket,
            endpoint: .hostPort(host: "mac.local", port: 4200)
        )
        #expect(!MobileMacPairingFloor.pairingRequiresMacUpdate(routes: [websocket]))
    }
}
