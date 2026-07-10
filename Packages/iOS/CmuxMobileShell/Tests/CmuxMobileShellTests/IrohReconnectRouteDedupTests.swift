import CMUXMobileCore
import Foundation
import Testing
@testable import CmuxMobileShell

@MainActor
@Suite struct IrohReconnectRouteDedupTests {
    @Test func reconnectDedupKeepsOverlappingAddressesFromDifferentProfiles() throws {
        let now = Date()
        let endpointID = try CmxIrohPeerIdentity(
            endpointID: String(repeating: "a", count: 64)
        )
        func route(id: String, profileID: String) throws -> CmxAttachRoute {
            try CmxAttachRoute(
                id: id,
                kind: .iroh,
                endpoint: .peer(
                    identity: endpointID,
                    pathHints: [
                        try CmxIrohPathHint(
                            kind: .directAddress,
                            value: "10.0.0.4:49152",
                            source: .customVPN,
                            privacyScope: .privateNetwork,
                            observedAt: now,
                            expiresAt: now.addingTimeInterval(300),
                            networkProfile: CmxIrohNetworkProfileKey(
                                source: .customVPN,
                                profileID: profileID
                            )
                        ),
                    ]
                )
            )
        }
        let siteA = try route(id: "iroh-site-a", profileID: "site-a")
        let siteB = try route(id: "iroh-site-b", profileID: "site-b")

        let merged = MobileShellComposite.mergedReconnectRoutes(
            ticketRoutes: [siteA],
            storedRoutes: [siteB]
        )

        #expect(Set(merged.map(\.id)) == ["iroh-site-a", "iroh-site-b"])
    }

    @Test func reconnectDedupReplacesStaleFreshnessForSameIrohPath() throws {
        let endpointID = try CmxIrohPeerIdentity(
            endpointID: String(repeating: "a", count: 64)
        )
        func route(id: String, observedAt: Date) throws -> CmxAttachRoute {
            try CmxAttachRoute(
                id: id,
                kind: .iroh,
                endpoint: .peer(
                    identity: endpointID,
                    pathHints: [
                        try CmxIrohPathHint(
                            kind: .directAddress,
                            value: "10.0.0.4:49152",
                            source: .customVPN,
                            privacyScope: .privateNetwork,
                            observedAt: observedAt,
                            expiresAt: observedAt.addingTimeInterval(300),
                            networkProfile: CmxIrohNetworkProfileKey(
                                source: .customVPN,
                                profileID: "site-a"
                            )
                        ),
                    ]
                )
            )
        }
        let fresh = try route(id: "fresh", observedAt: Date(timeIntervalSince1970: 2_000))
        let stale = try route(id: "stale", observedAt: Date(timeIntervalSince1970: 1_000))

        let merged = MobileShellComposite.mergedReconnectRoutes(
            ticketRoutes: [fresh],
            storedRoutes: [stale]
        )

        #expect(merged.map(\.id) == ["fresh"])
    }

    @Test func reconnectDedupIgnoresIrohHintSerializationOrder() throws {
        let now = Date(timeIntervalSince1970: 2_000)
        let identity = try CmxIrohPeerIdentity(
            endpointID: String(repeating: "a", count: 64)
        )
        let privateHint = try CmxIrohPathHint(
            kind: .directAddress,
            value: "10.0.0.4:49152",
            source: .customVPN,
            privacyScope: .privateNetwork,
            observedAt: now,
            expiresAt: now.addingTimeInterval(300),
            networkProfile: CmxIrohNetworkProfileKey(
                source: .customVPN,
                profileID: "site-a"
            )
        )
        let relayHint = try CmxIrohPathHint(
            kind: .relayURL,
            value: "https://relay.example.test/",
            source: .native,
            privacyScope: .publicInternet
        )
        let fresh = try CmxAttachRoute(
            id: "fresh",
            kind: .iroh,
            endpoint: .peer(identity: identity, pathHints: [privateHint, relayHint])
        )
        let stored = try CmxAttachRoute(
            id: "stored",
            kind: .iroh,
            endpoint: .peer(identity: identity, pathHints: [relayHint, privateHint])
        )

        let merged = MobileShellComposite.mergedReconnectRoutes(
            ticketRoutes: [fresh],
            storedRoutes: [stored]
        )

        #expect(merged.map(\.id) == ["fresh"])
    }
}
