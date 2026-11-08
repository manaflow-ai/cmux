import CMUXMobileCore
import Foundation
import Testing
@testable import CmuxMobileShell

private func opaqueProfileID(_ label: String) -> String {
    let hex = label.utf8.map { String(format: "%02x", $0) }.joined()
    return String((hex + String(repeating: "0", count: 64)).prefix(64))
}

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
                                profileID: opaqueProfileID(profileID)
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
            storedRoutes: [siteB],
            at: now
        )

        #expect(merged.map(\.id) == ["iroh-site-a"])
        guard case let .peer(_, pathHints) = merged[0].endpoint else {
            Issue.record("Expected an Iroh peer route")
            return
        }
        #expect(pathHints.compactMap(\.networkProfile?.profileID) == [
            opaqueProfileID("site-a"),
            opaqueProfileID("site-b"),
        ])
    }

    @Test func reconnectDedupReplacesStaleFreshnessForSameIrohPath() throws {
        let now = Date(timeIntervalSince1970: 2_000)
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
                                profileID: opaqueProfileID("site-a")
                            )
                        ),
                    ]
                )
            )
        }
        let fresh = try route(id: "fresh", observedAt: now.addingTimeInterval(-30))
        let stale = try route(id: "stale", observedAt: now.addingTimeInterval(-120))

        let merged = MobileShellComposite.mergedReconnectRoutes(
            ticketRoutes: [fresh],
            storedRoutes: [stale],
            at: now
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
                profileID: opaqueProfileID("site-a")
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
            storedRoutes: [stored],
            at: now
        )

        #expect(merged.map(\.id) == ["fresh"])
    }

    @Test func reconnectDedupIgnoresExpiredStoredHints() throws {
        let now = Date(timeIntervalSince1970: 2_000)
        let identity = try CmxIrohPeerIdentity(
            endpointID: String(repeating: "a", count: 64)
        )
        let relayHint = try CmxIrohPathHint(
            kind: .relayURL,
            value: "https://relay.example.test/",
            source: .native,
            privacyScope: .publicInternet
        )
        let expiredHint = try CmxIrohPathHint(
            kind: .directAddress,
            value: "10.0.0.4:49152",
            source: .customVPN,
            privacyScope: .privateNetwork,
            observedAt: now.addingTimeInterval(-120),
            expiresAt: now.addingTimeInterval(-60),
            networkProfile: CmxIrohNetworkProfileKey(
                source: .customVPN,
                profileID: opaqueProfileID("site-a")
            )
        )
        let fresh = try CmxAttachRoute(
            id: "fresh",
            kind: .iroh,
            endpoint: .peer(identity: identity, pathHints: [relayHint])
        )
        let stored = try CmxAttachRoute(
            id: "stored",
            kind: .iroh,
            endpoint: .peer(identity: identity, pathHints: [relayHint, expiredHint])
        )

        let merged = MobileShellComposite.mergedReconnectRoutes(
            ticketRoutes: [fresh],
            storedRoutes: [stored],
            at: now
        )

        #expect(merged.map(\.id) == ["fresh"])
    }

    @Test func reconnectDedupMergesAdditionalUsableHintsForSamePeer() throws {
        let now = Date(timeIntervalSince1970: 2_000)
        let identity = try CmxIrohPeerIdentity(
            endpointID: String(repeating: "a", count: 64)
        )
        let relayHint = try CmxIrohPathHint(
            kind: .relayURL,
            value: "https://relay.example.test/",
            source: .native,
            privacyScope: .publicInternet
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
                profileID: opaqueProfileID("site-a")
            )
        )
        let fresh = try CmxAttachRoute(
            id: "fresh",
            kind: .iroh,
            endpoint: .peer(identity: identity, pathHints: [relayHint])
        )
        let stored = try CmxAttachRoute(
            id: "stored",
            kind: .iroh,
            endpoint: .peer(identity: identity, pathHints: [relayHint, privateHint])
        )

        let merged = MobileShellComposite.mergedReconnectRoutes(
            ticketRoutes: [fresh],
            storedRoutes: [stored],
            at: now
        )

        #expect(merged.map(\.id) == ["fresh"])
        guard case let .peer(_, pathHints) = merged[0].endpoint else {
            Issue.record("Expected an Iroh peer route")
            return
        }
        #expect(pathHints == [relayHint, privateHint])
    }

    @Test func reconnectDedupMergesUsableHintsWhenRouteIDsMatch() throws {
        let now = Date(timeIntervalSince1970: 2_000)
        let identity = try CmxIrohPeerIdentity(
            endpointID: String(repeating: "a", count: 64)
        )
        let relayHint = try CmxIrohPathHint(
            kind: .relayURL,
            value: "https://relay.example.test/",
            source: .native,
            privacyScope: .publicInternet
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
                profileID: opaqueProfileID("site-a")
            )
        )
        let fresh = try CmxAttachRoute(
            id: "iroh",
            kind: .iroh,
            endpoint: .peer(identity: identity, pathHints: [relayHint])
        )
        let stored = try CmxAttachRoute(
            id: "iroh",
            kind: .iroh,
            endpoint: .peer(identity: identity, pathHints: [relayHint, privateHint])
        )

        let merged = MobileShellComposite.mergedReconnectRoutes(
            ticketRoutes: [fresh],
            storedRoutes: [stored],
            at: now
        )

        #expect(merged.map(\.id) == ["iroh"])
        guard case let .peer(_, pathHints) = merged[0].endpoint else {
            Issue.record("Expected an Iroh peer route")
            return
        }
        #expect(pathHints == [relayHint, privateHint])
    }

    @Test func reconnectDedupCapsMergedHintsAndPrefersFreshTicketHints() throws {
        let identity = try CmxIrohPeerIdentity(
            endpointID: String(repeating: "a", count: 64)
        )
        let freshHints = try (0..<CmxAttachEndpoint.maximumIrohPathHintCount).map { index in
            try CmxIrohPathHint(
                kind: .relayURL,
                value: "https://relay\(index).example.test/",
                source: .native,
                privacyScope: .publicInternet
            )
        }
        let storedHint = try CmxIrohPathHint(
            kind: .relayURL,
            value: "https://stored.example.test/",
            source: .native,
            privacyScope: .publicInternet
        )
        let fresh = try CmxAttachRoute(
            id: "fresh",
            kind: .iroh,
            endpoint: .peer(identity: identity, pathHints: freshHints)
        )
        let stored = try CmxAttachRoute(
            id: "stored",
            kind: .iroh,
            endpoint: .peer(identity: identity, pathHints: [storedHint])
        )

        let merged = MobileShellComposite.mergedReconnectRoutes(
            ticketRoutes: [fresh],
            storedRoutes: [stored],
            at: .distantPast
        )

        #expect(merged.map(\.id) == ["fresh"])
        guard case let .peer(_, pathHints) = merged[0].endpoint else {
            Issue.record("Expected an Iroh peer route")
            return
        }
        #expect(pathHints == freshHints)
    }
}
