import Foundation
import Testing
@testable import CMUXMobileCore

private let canonicalEndpointID = String(repeating: "a", count: 64)

private func profile(
    _ source: CmxIrohPathHintSource,
    _ profileID: String = "default"
) throws -> CmxIrohNetworkProfileKey {
    let hex = profileID.utf8.map { String(format: "%02x", $0) }.joined()
    let opaqueID = String((hex + String(repeating: "0", count: 64)).prefix(64))
    return try CmxIrohNetworkProfileKey(source: source, profileID: opaqueID)
}
@Test func dialPlanAdmitsOnlyExactManagedRelayURLsAndNeverLegacyRelayIdentifiers() throws {
    let managedURL = "https://use1-1.relay.lawrence.cmux.iroh.link/"
    let managed = try CmxIrohPathHint(
        kind: .relayURL,
        value: managedURL,
        source: .native,
        privacyScope: .publicInternet
    )
    let sameHostDifferentSpelling = try CmxIrohPathHint(
        kind: .relayURL,
        value: "https://use1-1.relay.lawrence.cmux.iroh.link",
        source: .native,
        privacyScope: .publicInternet
    )
    let attackerControlled = try CmxIrohPathHint(
        kind: .relayURL,
        value: "https://relay.attacker.example/",
        source: .native,
        privacyScope: .publicInternet
    )
    let legacyIdentifier = CmxIrohPathHint(
        legacyKind: .relayIdentifier,
        value: "use1",
        privacyScope: .publicInternet
    )
    let direct = try CmxIrohPathHint(
        kind: .directAddress,
        value: "8.8.8.8:49152",
        source: .native,
        privacyScope: .publicInternet
    )
    let endpoint = CmxAttachEndpoint.peer(
        identity: try CmxIrohPeerIdentity(endpointID: canonicalEndpointID),
        pathHints: [
            attackerControlled,
            legacyIdentifier,
            sameHostDifferentSpelling,
            managed,
            direct,
        ]
    )

    let plan = try #require(endpoint.irohDialPlan(
        at: Date(),
        managedRelayURLs: [managedURL]
    ))
    #expect(plan.publicPaths == [managed, direct])
    #expect(plan.privateFallbackPaths.isEmpty)

    let noRelayPlan = try #require(endpoint.irohDialPlan(
        at: Date(),
        managedRelayURLs: []
    ))
    #expect(noRelayPlan.publicPaths == [direct])
}

@Test func networkProfileIdentityDisambiguatesOverlappingPrivateNetworks() throws {
    let expiry = Date(timeIntervalSince1970: 2_000_000_000)
    let siteA = try CmxIrohPathHint(
        kind: .directAddress,
        value: "10.0.0.4:49152",
        source: .customVPN,
        privacyScope: .privateNetwork,
        observedAt: expiry.addingTimeInterval(-60),
        expiresAt: expiry,
        networkProfile: profile(.customVPN, "site-a")
    )
    let siteB = try CmxIrohPathHint(
        kind: .directAddress,
        value: "10.0.0.4:49152",
        source: .customVPN,
        privacyScope: .privateNetwork,
        observedAt: expiry.addingTimeInterval(-60),
        expiresAt: expiry,
        networkProfile: profile(.customVPN, "site-b")
    )
    let sameNameFromTailscale = try CmxIrohPathHint(
        kind: .directAddress,
        value: "100.64.0.4:49152",
        source: .tailscale,
        privacyScope: .privateNetwork,
        observedAt: expiry.addingTimeInterval(-60),
        expiresAt: expiry,
        networkProfile: profile(.tailscale, "site-a")
    )

    let expectedSiteAProfile = try profile(.customVPN, "site-a")
    let expectedSiteBProfile = try profile(.customVPN, "site-b")
    #expect(siteA != siteB)
    #expect(siteA.networkProfile == expectedSiteAProfile)
    #expect(siteB.networkProfile == expectedSiteBProfile)
    #expect(siteA.networkProfile != sameNameFromTailscale.networkProfile)

    let endpoint = CmxAttachEndpoint.peer(
        identity: try CmxIrohPeerIdentity(endpointID: canonicalEndpointID),
        pathHints: [siteA, siteB, sameNameFromTailscale]
    )
    let activePlan = try #require(endpoint.irohDialPlan(
        at: Date(timeIntervalSince1970: 1_999_999_999),
        managedRelayURLs: [],
        activeNetworkProfiles: [profile(.customVPN, "site-a")]
    ))
    #expect(activePlan.privateFallbackPaths == [siteA])
    let inactivePlan = try #require(endpoint.irohDialPlan(
        at: Date(timeIntervalSince1970: 1_999_999_999),
        managedRelayURLs: []
    ))
    #expect(inactivePlan.privateFallbackPaths.isEmpty)
}

@Test func providerAttributedIrohEndpointRoundTripsIdentityAndHintPolicy() throws {
    let expiry = Date(
        timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down) + 300
    )
    let endpoint = CmxAttachEndpoint.peer(
        identity: try CmxIrohPeerIdentity(endpointID: canonicalEndpointID),
        pathHints: [
            try CmxIrohPathHint(
                kind: .directAddress,
                value: "100.64.1.2:49152",
                source: .tailscale,
                privacyScope: .privateNetwork,
                observedAt: expiry.addingTimeInterval(-60),
                expiresAt: expiry,
                networkProfile: profile(.tailscale, "production")
            ),
            try CmxIrohPathHint(
                kind: .relayURL,
                value: "https://relay.example.test",
                source: .native,
                privacyScope: .publicInternet
            ),
        ]
    )
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601

    let decoded = try decoder.decode(
        CmxAttachEndpoint.self,
        from: encoder.encode(endpoint)
    )

    #expect(decoded == endpoint)
}

@Test func irohDisclosureAndPersistencePruneUnsafeHintScopes() throws {
    let now = Date()
    let publicRelay = try CmxIrohPathHint(
        kind: .relayURL,
        value: "https://relay.example.test/",
        source: .native,
        privacyScope: .publicInternet
    )
    let publicDirect = try CmxIrohPathHint(
        kind: .directAddress,
        value: "8.8.8.8:49152",
        source: .native,
        privacyScope: .publicInternet
    )
    let currentPrivate = try CmxIrohPathHint(
        kind: .directAddress,
        value: "100.64.1.2:49152",
        source: .tailscale,
        privacyScope: .privateNetwork,
        observedAt: now,
        expiresAt: now.addingTimeInterval(300),
        networkProfile: profile(.tailscale, "production")
    )
    let expiredPrivate = try CmxIrohPathHint(
        kind: .directAddress,
        value: "10.0.0.4:49152",
        source: .customVPN,
        privacyScope: .privateNetwork,
        observedAt: now.addingTimeInterval(-120),
        expiresAt: now.addingTimeInterval(-60),
        networkProfile: profile(.customVPN, "corp")
    )
    let route = try CmxAttachRoute(
        id: "iroh",
        kind: .iroh,
        endpoint: .peer(
            identity: CmxIrohPeerIdentity(endpointID: canonicalEndpointID),
            pathHints: [expiredPrivate, currentPrivate, publicDirect, publicRelay]
        )
    )

    let authenticated = try #require(route.disclosed(for: .authenticated, at: now))
    guard case let .peer(_, authenticatedHints) = authenticated.endpoint else {
        Issue.record("Expected authenticated Iroh peer route")
        return
    }
    #expect(authenticatedHints == [currentPrivate, publicDirect, publicRelay])

    let cloud = try #require(route.disclosed(for: .cloudRendezvous, at: now))
    guard case let .peer(_, cloudHints) = cloud.endpoint else {
        Issue.record("Expected cloud Iroh peer route")
        return
    }
    #expect(cloudHints == [publicRelay])

    let backup = try #require(route.disclosed(for: .pairedMacCloudBackup, at: now))
    guard case let .peer(_, backupHints) = backup.endpoint else {
        Issue.record("Expected backup Iroh peer route")
        return
    }
    #expect(backupHints == [publicRelay])

    #expect(route.disclosed(for: .publicStatus, at: now) == nil)

    let pairing = try #require(route.disclosed(for: .pairingQRCode, at: now))
    guard case let .peer(_, pairingHints) = pairing.endpoint else {
        Issue.record("Expected pairing Iroh peer route")
        return
    }
    #expect(pairingHints.isEmpty)

    let persisted = try JSONDecoder().decode(
        CmxAttachRoute.self,
        from: JSONEncoder().encode(authenticated)
    )
    guard case let .peer(_, persistedHints) = persisted.endpoint else {
        Issue.record("Expected persisted Iroh peer route")
        return
    }
    #expect(persistedHints == [currentPrivate, publicDirect, publicRelay])
}

@Test func materiallyFutureDatedPrivateHintsAreNeverAttemptedOrSerialized() throws {
    let now = Date()
    let networkProfile = try profile(.tailscale, "production")
    let toleratedClockSkewHint = try CmxIrohPathHint(
        kind: .directAddress,
        value: "100.64.1.3:49152",
        source: .tailscale,
        privacyScope: .privateNetwork,
        observedAt: now.addingTimeInterval(
            CmxIrohPathHint.maximumObservationClockSkew / 2
        ),
        expiresAt: now.addingTimeInterval(300),
        networkProfile: networkProfile
    )
    let futureHint = try CmxIrohPathHint(
        kind: .directAddress,
        value: "100.64.1.2:49152",
        source: .tailscale,
        privacyScope: .privateNetwork,
        observedAt: now.addingTimeInterval(2 * 60 * 60),
        expiresAt: now.addingTimeInterval(2 * 60 * 60 + 60),
        networkProfile: networkProfile
    )
    let route = try CmxAttachRoute(
        id: "iroh",
        kind: .iroh,
        endpoint: .peer(
            identity: CmxIrohPeerIdentity(endpointID: canonicalEndpointID),
            pathHints: [futureHint]
        )
    )

    #expect(toleratedClockSkewHint.isUsable(at: now))
    #expect(!futureHint.isUsable(at: now))
    let dialPlan = try #require(route.endpoint.irohDialPlan(
        at: now,
        managedRelayURLs: [],
        activeNetworkProfiles: [networkProfile]
    ))
    #expect(dialPlan.privateFallbackPaths.isEmpty)

    let disclosed = try #require(route.disclosed(for: .authenticated, at: now))
    guard case let .peer(_, disclosedHints) = disclosed.endpoint else {
        Issue.record("Expected disclosed Iroh peer route")
        return
    }
    #expect(disclosedHints.isEmpty)

    let persisted = try JSONDecoder().decode(
        CmxAttachRoute.self,
        from: JSONEncoder().encode(disclosed)
    )
    guard case let .peer(_, persistedHints) = persisted.endpoint else {
        Issue.record("Expected persisted Iroh peer route")
        return
    }
    #expect(persistedHints.isEmpty)
}

@Test func endpointEncodingIsClockIndependentAndDoesNotDowngradeFreshnessMetadata() throws {
    let observedAt = Date(timeIntervalSince1970: 1_000)
    let expiresAt = Date(timeIntervalSince1970: 1_060)
    let direct = try CmxIrohPathHint(
        kind: .directAddress,
        value: "8.8.8.8:49152",
        source: .native,
        privacyScope: .publicInternet,
        observedAt: observedAt,
        expiresAt: expiresAt
    )
    let relay = try CmxIrohPathHint(
        kind: .relayURL,
        value: "https://relay.example.test/",
        source: .native,
        privacyScope: .publicInternet,
        observedAt: observedAt,
        expiresAt: expiresAt
    )
    let endpoint = CmxAttachEndpoint.peer(
        identity: try CmxIrohPeerIdentity(endpointID: canonicalEndpointID),
        pathHints: [direct, relay]
    )
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys]

    let firstEncoding = try encoder.encode(endpoint)
    let secondEncoding = try encoder.encode(endpoint)

    #expect(firstEncoding == secondEncoding)
    let object = try #require(
        try JSONSerialization.jsonObject(with: firstEncoding) as? [String: Any]
    )
    #expect((object["path_hints"] as? [[String: Any]])?.count == 2)
    // The legacy fields cannot represent freshness metadata. Re-emitting
    // either hint there would make an expired path look timeless to an older
    // decoder.
    #expect(object["direct_addrs"] == nil)
    #expect(object["relay_url"] == nil)
    #expect(object["relay_hint"] == nil)

    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let roundTrippedEndpoint = try decoder.decode(CmxAttachEndpoint.self, from: firstEncoding)
    #expect(roundTrippedEndpoint == endpoint)
}

@Test func publicStatusDisclosesNoAttachRoutes() throws {
    let routes = try [
        CmxAttachRoute(
            id: "iroh",
            kind: .iroh,
            endpoint: .peer(
                identity: CmxIrohPeerIdentity(endpointID: canonicalEndpointID),
                pathHints: [
                    CmxIrohPathHint(
                        kind: .relayURL,
                        value: "https://relay.example.test/",
                        source: .native,
                        privacyScope: .publicInternet
                    ),
                ]
            )
        ),
        CmxAttachRoute(
            id: "tailscale",
            kind: .tailscale,
            endpoint: .hostPort(host: "100.64.1.2", port: 49152)
        ),
        CmxAttachRoute(
            id: "debug",
            kind: .debugLoopback,
            endpoint: .hostPort(host: "127.0.0.1", port: 49152)
        ),
        CmxAttachRoute(
            id: "websocket",
            kind: .websocket,
            endpoint: .url("wss://private.example.test/connect?token=secret")
        ),
    ]

    for route in routes {
        #expect(route.disclosed(for: .authenticated, at: Date()) == route)
        #expect(route.disclosed(for: .publicStatus, at: Date()) == nil)
    }
}

@Test func legacyFreeFormDirectHintStillDecodesButCannotBeUsedOrPromoted() throws {
    let data = Data("""
    {
      "id": "iroh",
      "kind": "iroh",
      "endpoint": {
        "type": "peer",
        "id": "\(canonicalEndpointID)",
        "direct_addrs": ["old-hostname.example:49152"]
      }
    }
    """.utf8)

    let route = try JSONDecoder().decode(CmxAttachRoute.self, from: data)
    guard case let .peer(_, pathHints) = route.endpoint else {
        Issue.record("Expected an Iroh peer endpoint")
        return
    }
    let hint = try #require(pathHints.first)
    #expect(hint.use == .fallbackOnly)
    #expect(!hint.isUsable(at: .distantPast))

    let reencoded = try JSONEncoder().encode(route)
    let redecoded = try JSONDecoder().decode(CmxAttachRoute.self, from: reencoded)
    guard case let .peer(redecodedIdentity, redecodedHints) = redecoded.endpoint else {
        Issue.record("Expected an Iroh peer endpoint")
        return
    }
    #expect(redecodedIdentity.endpointID == canonicalEndpointID)
    // A current producer deliberately does not downgrade private fallbacks to
    // legacy `direct_addrs`, whose consumers cannot enforce expiry or scope.
    #expect(redecodedHints.isEmpty)
}
@Test func legacyUnsafeRelayURLStillDecodesButCannotBeUsedOrReemitted() throws {
    let data = Data("""
    {
      "id": "iroh",
      "kind": "iroh",
      "endpoint": {
        "type": "peer",
        "id": "\(canonicalEndpointID)",
        "relay_url": "https://user:secret@relay.example.test/"
      }
    }
    """.utf8)

    let route = try JSONDecoder().decode(CmxAttachRoute.self, from: data)
    guard case let .peer(_, pathHints) = route.endpoint else {
        Issue.record("Expected an Iroh peer endpoint")
        return
    }
    let hint = try #require(pathHints.first)
    #expect(!hint.isSafeForCurrentWireFormat)
    #expect(!hint.isUsable(at: .distantPast))

    let reencoded = try JSONEncoder().encode(route)
    let redecoded = try JSONDecoder().decode(CmxAttachRoute.self, from: reencoded)
    guard case let .peer(_, redecodedHints) = redecoded.endpoint else {
        Issue.record("Expected an Iroh peer endpoint")
        return
    }
    #expect(redecodedHints.isEmpty)
}
