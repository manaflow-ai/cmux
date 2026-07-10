import Foundation
import Testing
@testable import CMUXMobileCore

private let canonicalEndpointID = String(repeating: "a", count: 64)

private func profile(
    _ source: CmxIrohPathHintSource,
    _ profileID: String = "default"
) throws -> CmxIrohNetworkProfileKey {
    try CmxIrohNetworkProfileKey(source: source, profileID: profileID)
}

@Test func irohEndpointIDRequiresCanonicalLowercaseHex() throws {
    #expect((try CmxIrohPeerIdentity(endpointID: canonicalEndpointID)).endpointID == canonicalEndpointID)
    for invalid in [
        "",
        String(repeating: "a", count: 63),
        String(repeating: "a", count: 65),
        String(repeating: "A", count: 64),
        String(repeating: "g", count: 64),
    ] {
        #expect(throws: CmxIrohPeerIdentityError.nonCanonicalEndpointID) {
            _ = try CmxIrohPeerIdentity(endpointID: invalid)
        }
    }
}

@Test func attachTicketChoosesFirstSupportedRouteByPriority() throws {
    let iroh = try CmxAttachRoute(
        id: "iroh",
        kind: .iroh,
        endpoint: .peer(
            id: canonicalEndpointID,
            relayHint: "relay-1",
            directAddrs: ["192.168.1.20:3478"],
            relayURL: "https://relay.example.test"
        ),
        priority: 0
    )
    let tailscale = try CmxAttachRoute(
        id: "tailscale",
        kind: .tailscale,
        endpoint: .hostPort(host: "100.64.1.2", port: 49831),
        priority: 1
    )
    let ticket = try CmxAttachTicket(
        workspaceID: "workspace-1",
        terminalID: "terminal-1",
        macDeviceID: "mac-1",
        macDisplayName: "Studio",
        routes: [tailscale, iroh],
        expiresAt: Date(timeIntervalSince1970: 2_000_000_000)
    )

    #expect(ticket.preferredRoute(supportedKinds: [.tailscale, .iroh]) == iroh)
    #expect(ticket.preferredRoute(supportedKinds: [.websocket]) == nil)
    #expect(ticket.preferredRoute(supportedKinds: []) == nil)
}

@Test func irohPeerIdentityIsIndependentFromOrderedProviderPathHints() throws {
    let now = Date(timeIntervalSince1970: 2_000_000_000)
    let relay = try CmxIrohPathHint(
        kind: .relayURL,
        value: "https://relay.example.test",
        source: .native,
        privacyScope: .publicInternet
    )
    let expiredLAN = try CmxIrohPathHint(
        kind: .directAddress,
        value: "192.168.1.20:49152",
        source: .lan,
        privacyScope: .localNetwork,
        observedAt: now.addingTimeInterval(-60),
        expiresAt: now.addingTimeInterval(-1),
        networkProfile: profile(.lan, "studio")
    )
    let tailscale = try CmxIrohPathHint(
        kind: .directAddress,
        value: "100.64.1.2:49152",
        source: .tailscale,
        privacyScope: .privateNetwork,
        observedAt: now,
        expiresAt: now.addingTimeInterval(60),
        networkProfile: profile(.tailscale, "production")
    )
    let customVPN = try CmxIrohPathHint(
        kind: .directAddress,
        value: "10.10.0.8:49152",
        source: .customVPN,
        privacyScope: .privateNetwork,
        observedAt: now,
        expiresAt: now.addingTimeInterval(30),
        networkProfile: profile(.customVPN, "corp")
    )
    let endpoint = CmxAttachEndpoint.peer(
        identity: try CmxIrohPeerIdentity(endpointID: canonicalEndpointID),
        pathHints: [tailscale, expiredLAN, relay, customVPN]
    )

    #expect(endpoint.irohPeerIdentity == (try CmxIrohPeerIdentity(endpointID: canonicalEndpointID)))
    #expect(tailscale.use == .fallbackOnly)
    #expect(expiredLAN.use == .fallbackOnly)
    #expect(customVPN.use == .fallbackOnly)
    #expect(relay.use == .primary)
    let firstPhaseOnly = try #require(endpoint.irohDialPlan(at: now))
    #expect(firstPhaseOnly.publicPaths == [relay])
    #expect(firstPhaseOnly.privateFallbackPaths.isEmpty)

    let fullPlan = try #require(endpoint.irohDialPlan(
        at: now,
        activeNetworkProfiles: [
            profile(.tailscale, "production"),
            profile(.customVPN, "corp"),
        ]
    ))
    #expect(fullPlan.publicPaths == [relay])
    #expect(fullPlan.privateFallbackPaths == [tailscale, customVPN])
}

@Test func privateProviderHintsRequireMatchingScopeAndExpiry() throws {
    let expiry = Date(timeIntervalSince1970: 2_000_000_000)

    #expect(throws: CmxIrohPathHintError.incompatiblePrivacyScope(
        source: .tailscale,
        scope: .publicInternet
    )) {
        _ = try CmxIrohPathHint(
            kind: .directAddress,
            value: "8.8.8.8:49152",
            source: .tailscale,
            privacyScope: .publicInternet,
            expiresAt: expiry
        )
    }
    #expect(throws: CmxIrohPathHintError.missingPrivateHintObservation) {
        _ = try CmxIrohPathHint(
            kind: .directAddress,
            value: "192.168.1.20:49152",
            source: .lan,
            privacyScope: .localNetwork
        )
    }
    #expect(throws: CmxIrohPathHintError.missingPrivateHintObservation) {
        _ = try CmxIrohPathHint(
            kind: .directAddress,
            value: "10.0.0.4:49152",
            source: .native,
            privacyScope: .privateNetwork
        )
    }
    #expect(throws: CmxIrohPathHintError.missingPrivateHintExpiry) {
        _ = try CmxIrohPathHint(
            kind: .directAddress,
            value: "10.0.0.4:49152",
            source: .customVPN,
            privacyScope: .privateNetwork,
            observedAt: expiry.addingTimeInterval(-60),
            networkProfile: profile(.customVPN)
        )
    }
    #expect(throws: CmxIrohPathHintError.missingPrivateHintNetworkProfile) {
        _ = try CmxIrohPathHint(
            kind: .directAddress,
            value: "10.0.0.4:49152",
            source: .customVPN,
            privacyScope: .privateNetwork,
            observedAt: expiry.addingTimeInterval(-60),
            expiresAt: expiry
        )
    }
    #expect(throws: CmxIrohPathHintError.privateHintTTLExceedsMaximum) {
        _ = try CmxIrohPathHint(
            kind: .directAddress,
            value: "10.0.0.4:49152",
            source: .customVPN,
            privacyScope: .privateNetwork,
            observedAt: expiry.addingTimeInterval(-(CmxIrohPathHint.maximumPrivateHintTTL + 1)),
            expiresAt: expiry,
            networkProfile: profile(.customVPN)
        )
    }
    #expect(throws: CmxIrohPathHintError.networkProfileSourceMismatch) {
        _ = try CmxIrohPathHint(
            kind: .directAddress,
            value: "10.0.0.4:49152",
            source: .customVPN,
            privacyScope: .privateNetwork,
            observedAt: expiry.addingTimeInterval(-60),
            expiresAt: expiry,
            networkProfile: profile(.tailscale)
        )
    }
}

@Test func irohPeerRouteCapsPathHintsAtSixteen() throws {
    let hint = try CmxIrohPathHint(
        kind: .relayURL,
        value: "https://relay.example.test/",
        source: .native,
        privacyScope: .publicInternet
    )
    let maximum = CmxAttachEndpoint.maximumIrohPathHintCount
    let endpointID = try CmxIrohPeerIdentity(endpointID: canonicalEndpointID)

    _ = try CmxAttachRoute(
        id: "iroh",
        kind: .iroh,
        endpoint: .peer(
            identity: endpointID,
            pathHints: Array(repeating: hint, count: maximum)
        )
    )

    #expect(throws: CmxAttachRouteError.tooManyPeerPathHints(
        actual: maximum + 1,
        maximum: maximum
    )) {
        _ = try CmxAttachRoute(
            id: "iroh",
            kind: .iroh,
            endpoint: .peer(
                identity: endpointID,
                pathHints: Array(repeating: hint, count: maximum + 1)
            )
        )
    }
}

@Test func directPathHintsAcceptOnlyCanonicalIPSocketAddresses() throws {
    let expiry = Date(timeIntervalSince1970: 2_000_000_000)
    let ipv4 = try CmxIrohPathHint(
        kind: .directAddress,
        value: "10.0.0.4:49152",
        source: .customVPN,
        privacyScope: .privateNetwork,
        observedAt: expiry.addingTimeInterval(-60),
        expiresAt: expiry,
        networkProfile: profile(.customVPN)
    )
    let ipv6 = try CmxIrohPathHint(
        kind: .directAddress,
        value: "[fd7a:115c:a1e0::1]:49152",
        source: .tailscale,
        privacyScope: .privateNetwork,
        observedAt: expiry.addingTimeInterval(-60),
        expiresAt: expiry,
        networkProfile: profile(.tailscale)
    )
    #expect(ipv4.value == "10.0.0.4:49152")
    #expect(ipv6.value == "[fd7a:115c:a1e0::1]:49152")

    for malformed in [
        "mac.tailnet.ts.net:49152",
        "https://10.0.0.4:49152",
        "user@10.0.0.4:49152",
        "10.0.0.0/24:49152",
        "10.0.0.4",
        "10.0.0.4:0",
        "010.0.0.4:49152",
        "[fe80::1%en0]:49152",
    ] {
        #expect(throws: CmxIrohPathHintError.invalidDirectAddress) {
            _ = try CmxIrohPathHint(
                kind: .directAddress,
                value: malformed,
                source: .customVPN,
                privacyScope: .privateNetwork,
                observedAt: expiry.addingTimeInterval(-60),
                expiresAt: expiry,
                networkProfile: profile(.customVPN)
            )
        }
    }
}

@Test func directPathHintsRejectNonPeerAndMetadataAddresses() throws {
    let expiry = Date(timeIntervalSince1970: 2_000_000_000)
    for forbidden in [
        "0.0.0.0:49152",
        "127.0.0.1:49152",
        "224.0.0.1:49152",
        "255.255.255.255:49152",
        "169.254.169.254:49152",
        "[::]:49152",
        "[::1]:49152",
        "[ff02::1]:49152",
        "[fe80::1]:49152",
        "[fd00:ec2::254]:49152",
    ] {
        #expect(throws: CmxIrohPathHintError.forbiddenDirectAddress) {
            _ = try CmxIrohPathHint(
                kind: .directAddress,
                value: forbidden,
                source: .native,
                privacyScope: .localNetwork,
                observedAt: expiry.addingTimeInterval(-60),
                expiresAt: expiry,
                networkProfile: profile(.native)
            )
        }
    }

    let legitimateLinkLocal = try CmxIrohPathHint(
        kind: .directAddress,
        value: "169.254.42.7:49152",
        source: .lan,
        privacyScope: .localNetwork,
        observedAt: expiry.addingTimeInterval(-60),
        expiresAt: expiry,
        networkProfile: profile(.lan)
    )
    #expect(legitimateLinkLocal.value == "169.254.42.7:49152")
}

@Test func publicDirectPathHintsRequireGloballyRoutableAddresses() throws {
    let publicIPv4 = try CmxIrohPathHint(
        kind: .directAddress,
        value: "8.8.8.8:49152",
        source: .native,
        privacyScope: .publicInternet
    )
    let publicIPv6 = try CmxIrohPathHint(
        kind: .directAddress,
        value: "[2606:4700:4700::1111]:49152",
        source: .native,
        privacyScope: .publicInternet
    )
    #expect(publicIPv4.use == .primary)
    #expect(publicIPv6.use == .primary)

    for nonGlobal in [
        "10.0.0.4:49152",
        "172.16.0.4:49152",
        "192.168.1.4:49152",
        "100.64.1.4:49152",
        "169.254.42.7:49152",
        "192.0.2.4:49152",
        "198.18.0.4:49152",
        "198.51.100.4:49152",
        "203.0.113.4:49152",
        "[fd7a:115c:a1e0::1]:49152",
        "[2001:db8::1]:49152",
        "[3fff::1]:49152",
    ] {
        #expect(throws: CmxIrohPathHintError.nonGlobalPublicDirectAddress) {
            _ = try CmxIrohPathHint(
                kind: .directAddress,
                value: nonGlobal,
                source: .native,
                privacyScope: .publicInternet
            )
        }
    }

    let expiry = Date(timeIntervalSince1970: 2_000_000_000)
    _ = try CmxIrohPathHint(
        kind: .directAddress,
        value: "10.0.0.4:49152",
        source: .customVPN,
        privacyScope: .privateNetwork,
        observedAt: expiry.addingTimeInterval(-60),
        expiresAt: expiry,
        networkProfile: profile(.customVPN)
    )
    _ = try CmxIrohPathHint(
        kind: .directAddress,
        value: "169.254.42.7:49152",
        source: .lan,
        privacyScope: .localNetwork,
        observedAt: expiry.addingTimeInterval(-60),
        expiresAt: expiry,
        networkProfile: profile(.lan)
    )
    _ = try CmxIrohPathHint(
        kind: .directAddress,
        value: "[fd7a:115c:a1e0::1]:49152",
        source: .tailscale,
        privacyScope: .privateNetwork,
        observedAt: expiry.addingTimeInterval(-60),
        expiresAt: expiry,
        networkProfile: profile(.tailscale)
    )
    _ = try CmxIrohPathHint(
        kind: .directAddress,
        value: "192.0.2.4:49152",
        source: .customVPN,
        privacyScope: .privateNetwork,
        observedAt: expiry.addingTimeInterval(-60),
        expiresAt: expiry,
        networkProfile: profile(.customVPN)
    )
    _ = try CmxIrohPathHint(
        kind: .directAddress,
        value: "[2001:db8::1]:49152",
        source: .customVPN,
        privacyScope: .privateNetwork,
        observedAt: expiry.addingTimeInterval(-60),
        expiresAt: expiry,
        networkProfile: profile(.customVPN)
    )
}

@Test func relayPathHintsAcceptOnlyCredentialFreeRootHTTPSURLs() throws {
    let valid = try CmxIrohPathHint(
        kind: .relayURL,
        value: "https://use1-1.relay.lawrence.cmux.iroh.link/",
        source: .native,
        privacyScope: .publicInternet
    )
    #expect(valid.use == .primary)

    for unsafe in [
        "http://relay.example.test/",
        "https://user:secret@relay.example.test/",
        "https://relay.example.test/admin",
        "https://relay.example.test/?token=secret",
        "https://169.254.169.254/",
        "https://169.254.42.7/",
        "https://10.0.0.1/",
        "https://127.0.0.1/",
        "https://[::1]/",
        "https://[fd7a:115c:a1e0::1]/",
        "https://relay.local/",
        "https://0177.0.0.1/",
        "https://0x7f.0.0.1/",
        "https://127.1/",
        "https://localhost./",
        "https://relay..example.test/",
        "https://-relay.example.test/",
        "https://relay.example-.test/",
        "https://relay.example.123/",
        "relay.example.test",
    ] {
        #expect(throws: CmxIrohPathHintError.unsafeRelayURL) {
            _ = try CmxIrohPathHint(
                kind: .relayURL,
                value: unsafe,
                source: .native,
                privacyScope: .publicInternet
            )
        }
    }

    #expect(throws: CmxIrohPathHintError.relayHintRequiresNativePublicSource) {
        _ = try CmxIrohPathHint(
            kind: .relayURL,
            value: "https://relay.example.test/",
            source: .native,
            privacyScope: .privateNetwork
        )
    }
    #expect(throws: CmxIrohPathHintError.relayHintRequiresNativePublicSource) {
        _ = try CmxIrohPathHint(
            kind: .relayIdentifier,
            value: "use1",
            source: .tailscale,
            privacyScope: .privateNetwork
        )
    }
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

    #expect(siteA != siteB)
    #expect(siteA.networkProfile == (try profile(.customVPN, "site-a")))
    #expect(siteB.networkProfile == (try profile(.customVPN, "site-b")))
    #expect(siteA.networkProfile != sameNameFromTailscale.networkProfile)

    let endpoint = CmxAttachEndpoint.peer(
        identity: try CmxIrohPeerIdentity(endpointID: canonicalEndpointID),
        pathHints: [siteA, siteB, sameNameFromTailscale]
    )
    let activePlan = try #require(endpoint.irohDialPlan(
        at: Date(timeIntervalSince1970: 1_999_999_999),
        activeNetworkProfiles: [profile(.customVPN, "site-a")]
    ))
    #expect(activePlan.privateFallbackPaths == [siteA])
    let inactivePlan = try #require(endpoint.irohDialPlan(
        at: Date(timeIntervalSince1970: 1_999_999_999)
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
            pathHints: [expiredPrivate, currentPrivate, publicRelay]
        )
    )

    let authenticated = try #require(route.disclosed(for: .authenticated, at: now))
    guard case let .peer(_, authenticatedHints) = authenticated.endpoint else {
        Issue.record("Expected authenticated Iroh peer route")
        return
    }
    #expect(authenticatedHints == [currentPrivate, publicRelay])

    let publicStatus = try #require(route.disclosed(for: .publicStatus, at: now))
    guard case let .peer(_, publicHints) = publicStatus.endpoint else {
        Issue.record("Expected public Iroh peer route")
        return
    }
    #expect(publicHints == [publicRelay])

    let pairing = try #require(route.disclosed(for: .pairingQRCode, at: now))
    guard case let .peer(_, pairingHints) = pairing.endpoint else {
        Issue.record("Expected pairing Iroh peer route")
        return
    }
    #expect(pairingHints.isEmpty)

    let persisted = try JSONDecoder().decode(
        CmxAttachRoute.self,
        from: JSONEncoder().encode(route)
    )
    guard case let .peer(_, persistedHints) = persisted.endpoint else {
        Issue.record("Expected persisted Iroh peer route")
        return
    }
    #expect(persistedHints == [currentPrivate, publicRelay])
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
        from: JSONEncoder().encode(route)
    )
    guard case let .peer(_, persistedHints) = persisted.endpoint else {
        Issue.record("Expected persisted Iroh peer route")
        return
    }
    #expect(persistedHints.isEmpty)
}

@Test func publicStatusOnlyDisclosesPrivacyClassifiedIrohRoutes() throws {
    let routes = try [
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

@Test func attachTicketUsesDebugLoopbackBeforeTailscaleWhenBothAreSupported() throws {
    let loopback = try CmxAttachRoute(
        id: "debug",
        kind: .debugLoopback,
        endpoint: .hostPort(host: "127.0.0.1", port: 49831),
        priority: 0
    )
    let tailscale = try CmxAttachRoute(
        id: "tailscale",
        kind: .tailscale,
        endpoint: .hostPort(host: "100.64.1.2", port: 49831),
        priority: 10
    )
    let ticket = try CmxAttachTicket(
        workspaceID: "workspace-1",
        terminalID: "terminal-1",
        macDeviceID: "mac-1",
        macDisplayName: "Studio",
        routes: [tailscale, loopback],
        expiresAt: Date(timeIntervalSince1970: 2_000_000_000)
    )

    #expect(ticket.preferredRoute(supportedKinds: [.tailscale, .debugLoopback]) == loopback)
    #expect(ticket.preferredRoute(supportedKinds: [.tailscale]) == tailscale)
}

@Test func attachTicketRoundTripsAllEndpointKinds() throws {
    let privateHintExpiry = Date(
        timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down) + 300
    )
    let routes = try [
        CmxAttachRoute(
            id: "tailscale",
            kind: .tailscale,
            endpoint: .hostPort(host: "100.64.1.2", port: 49831)
        ),
        CmxAttachRoute(
            id: "iroh",
            kind: .iroh,
            endpoint: .peer(
                identity: try CmxIrohPeerIdentity(endpointID: canonicalEndpointID),
                pathHints: [
                    try CmxIrohPathHint(
                        kind: .directAddress,
                        value: "100.64.1.2:49152",
                        source: .tailscale,
                        privacyScope: .privateNetwork,
                        observedAt: privateHintExpiry.addingTimeInterval(-60),
                        expiresAt: privateHintExpiry,
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
        ),
        CmxAttachRoute(
            id: "websocket",
            kind: .websocket,
            endpoint: .url("wss://cmux.example.test/terminal")
        ),
    ]
    let ticket = try CmxAttachTicket(
        workspaceID: "workspace-1",
        terminalID: nil,
        macDeviceID: "mac-1",
        macDisplayName: nil,
        routes: routes,
        expiresAt: Date(timeIntervalSince1970: 2_000_000_000),
        authToken: "ticket-secret"
    )
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys]
    let data = try encoder.encode(ticket)
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601

    let decoded = try decoder.decode(CmxAttachTicket.self, from: data)

    #expect(decoded == ticket)
}

@Test func attachTicketRejectsEmptyAuthToken() throws {
    let route = try CmxAttachRoute(
        id: "tailscale",
        kind: .tailscale,
        endpoint: .hostPort(host: "100.64.1.2", port: 49831)
    )

    #expect(throws: CmxAttachTicketError.emptyAuthToken) {
        _ = try CmxAttachTicket(
            workspaceID: "workspace-1",
            terminalID: nil,
            macDeviceID: "mac-1",
            macDisplayName: nil,
            routes: [route],
            expiresAt: Date(timeIntervalSince1970: 2_000_000_000),
            authToken: "  "
        )
    }
}

@Test func attachTicketConstructsWithPastExpiryAndReportsExpired() throws {
    // Expiry is data for token consumers, not a structural validity gate: a
    // stale ticket still constructs (a QR scanned long after it was shown must
    // keep pairing), and `isExpired(at:)` reports its token lifetime.
    let route = try CmxAttachRoute(
        id: "tailscale",
        kind: .tailscale,
        endpoint: .hostPort(host: "100.64.1.2", port: 49831)
    )

    let ticket = try CmxAttachTicket(
        workspaceID: "workspace-1",
        terminalID: nil,
        macDeviceID: "mac-1",
        macDisplayName: nil,
        routes: [route],
        expiresAt: Date(timeIntervalSince1970: 1_000)
    )
    #expect(ticket.isExpired(at: Date(timeIntervalSince1970: 2_000)))
    #expect(!ticket.isExpired(at: Date(timeIntervalSince1970: 500)))
}

@Test func attachTicketWithoutExpiryNeverExpires() throws {
    let route = try CmxAttachRoute(
        id: "tailscale",
        kind: .tailscale,
        endpoint: .hostPort(host: "100.64.1.2", port: 49831)
    )

    let ticket = try CmxAttachTicket(
        workspaceID: "",
        terminalID: nil,
        macDeviceID: "mac-1",
        macDisplayName: nil,
        routes: [route]
    )
    #expect(ticket.expiresAt == nil)
    #expect(!ticket.isExpired(at: .distantFuture))
}

@Test func attachRouteDecodesIrohAddressHintsFromExperimentRouteJSON() throws {
    let data = Data("""
    {
      "id": "iroh",
      "kind": "iroh",
      "endpoint": {
        "type": "peer",
        "id": "\(canonicalEndpointID)",
        "direct_addrs": ["192.168.1.20:49152", "100.64.1.2:49152"],
        "relay_url": "https://relay.example.test"
      },
      "priority": 20
    }
    """.utf8)

    let route = try JSONDecoder().decode(CmxAttachRoute.self, from: data)

    #expect(route.id == "iroh")
    #expect(route.kind == .iroh)
    #expect(route.priority == 20)
    guard case let .peer(identity, pathHints) = route.endpoint else {
        Issue.record("Expected an Iroh peer endpoint")
        return
    }
    #expect(identity.endpointID == canonicalEndpointID)
    #expect(pathHints.filter { $0.kind == .relayIdentifier }.isEmpty)
    #expect(pathHints.filter { $0.kind == .directAddress }.map(\.value) == [
        "192.168.1.20:49152",
        "100.64.1.2:49152",
    ])
    #expect(pathHints.first { $0.kind == .relayURL }?.value == "https://relay.example.test")
    #expect(pathHints.filter { $0.kind == .directAddress }.allSatisfy {
        $0.use == .fallbackOnly && !$0.isUsable(at: .distantPast)
    })
}

@Test func attachRouteDecodesLegacyPeerRouteWithoutIrohAddressHints() throws {
    let data = Data("""
    {
      "id": "iroh",
      "kind": "iroh",
      "endpoint": {
        "type": "peer",
        "id": "\(canonicalEndpointID)",
        "relay_hint": "legacy-relay"
      },
      "priority": 20
    }
    """.utf8)

    let route = try JSONDecoder().decode(CmxAttachRoute.self, from: data)

    guard case let .peer(identity, pathHints) = route.endpoint else {
        Issue.record("Expected an Iroh peer endpoint")
        return
    }
    #expect(identity.endpointID == canonicalEndpointID)
    #expect(pathHints.first { $0.kind == .relayIdentifier }?.value == "legacy-relay")
    #expect(pathHints.filter { $0.kind == .directAddress }.isEmpty)
    #expect(pathHints.filter { $0.kind == .relayURL }.isEmpty)
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

@Test func attachRouteDecoderDefaultsMissingPriorityToZero() throws {
    let data = Data("""
    {
      "id": "tailscale",
      "kind": "tailscale",
      "endpoint": {
        "type": "host_port",
        "host": "100.64.1.2",
        "port": 49831
      }
    }
    """.utf8)

    let route = try JSONDecoder().decode(CmxAttachRoute.self, from: data)

    #expect(route.kind == .tailscale)
    #expect(route.endpoint == .hostPort(host: "100.64.1.2", port: 49831))
    #expect(route.priority == 0)
}

@Test func attachRouteRejectsMismatchedEndpointKind() throws {
    #expect(throws: CmxAttachRouteError.endpointMismatch(
        kind: .iroh,
        endpoint: .hostPort(host: "100.64.1.2", port: 49831)
    )) {
        _ = try CmxAttachRoute(
            id: "bad",
            kind: .iroh,
            endpoint: .hostPort(host: "100.64.1.2", port: 49831)
        )
    }
}

@Test func attachRouteDecoderRejectsMismatchedEndpointKind() throws {
    let data = Data("""
    {
      "id": "bad",
      "kind": "iroh",
      "endpoint": {
        "type": "host_port",
        "host": "100.64.1.2",
        "port": 49831
      },
      "priority": 0
    }
    """.utf8)

    #expect(throws: CmxAttachRouteError.endpointMismatch(
        kind: .iroh,
        endpoint: .hostPort(host: "100.64.1.2", port: 49831)
    )) {
        _ = try JSONDecoder().decode(CmxAttachRoute.self, from: data)
    }
}

@Test func attachTicketDecoderRejectsNoRoutes() throws {
    let data = Data("""
    {
      "version": 1,
      "workspaceID": "workspace-1",
      "terminalID": null,
      "macDeviceID": "mac-1",
      "macDisplayName": null,
      "routes": [],
      "expiresAt": "2033-05-18T03:33:20Z"
    }
    """.utf8)
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601

    #expect(throws: CmxAttachTicketError.noRoutes) {
        _ = try decoder.decode(CmxAttachTicket.self, from: data)
    }
}

@Test func attachTicketDecoderAcceptsExpiredTicketAndPreservesExpiry() throws {
    // A legacy full-key QR scanned long after it was shown must keep
    // decoding; expiry is preserved as data for token consumers, not
    // enforced at decode time.
    let data = Data("""
    {
      "version": 1,
      "workspaceID": "workspace-1",
      "terminalID": null,
      "macDeviceID": "mac-1",
      "macDisplayName": null,
      "routes": [
        {
          "id": "tailscale",
          "kind": "tailscale",
          "endpoint": {
            "type": "host_port",
            "host": "100.64.1.2",
            "port": 49831
          },
          "priority": 0
        }
      ],
      "expiresAt": "2001-01-01T00:00:00Z"
    }
    """.utf8)
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601

    let ticket = try decoder.decode(CmxAttachTicket.self, from: data)
    #expect(ticket.expiresAt == Date(timeIntervalSince1970: 978_307_200))
    #expect(ticket.isExpired(at: Date()))
}

@Test func attachTicketDecoderAcceptsMissingExpiry() throws {
    let data = Data("""
    {
      "version": 1,
      "workspaceID": "workspace-1",
      "terminalID": null,
      "macDeviceID": "mac-1",
      "macDisplayName": null,
      "routes": [
        {
          "id": "tailscale",
          "kind": "tailscale",
          "endpoint": {
            "type": "host_port",
            "host": "100.64.1.2",
            "port": 49831
          },
          "priority": 0
        }
      ]
    }
    """.utf8)
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601

    let ticket = try decoder.decode(CmxAttachTicket.self, from: data)
    #expect(ticket.expiresAt == nil)
    #expect(!ticket.isExpired(at: Date()))
}

@Test func attachTicketDecoderRejectsInvalidNestedRoute() throws {
    let data = Data("""
    {
      "version": 1,
      "workspaceID": "workspace-1",
      "terminalID": null,
      "macDeviceID": "mac-1",
      "macDisplayName": null,
      "routes": [
        {
          "id": "bad",
          "kind": "iroh",
          "endpoint": {
            "type": "host_port",
            "host": "100.64.1.2",
            "port": 49831
          },
          "priority": 0
        }
      ],
      "expiresAt": "2033-05-18T03:33:20Z"
    }
    """.utf8)
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601

    #expect(throws: CmxAttachRouteError.endpointMismatch(
        kind: .iroh,
        endpoint: .hostPort(host: "100.64.1.2", port: 49831)
    )) {
        _ = try decoder.decode(CmxAttachTicket.self, from: data)
    }
}

@Test func routeTransportFactoryDispatchesByRouteKind() throws {
    let factory = try CmxRouteTransportFactory([
        CmxRouteTransportFactoryRegistration(
            kind: .tailscale,
            factory: TaggedTransportFactory(tag: "tailscale-tcp")
        ),
        CmxRouteTransportFactoryRegistration(
            kind: .iroh,
            factory: TaggedTransportFactory(tag: "iroh-peer")
        ),
    ])
    let tailscaleRoute = try CmxAttachRoute(
        id: "tailscale",
        kind: .tailscale,
        endpoint: .hostPort(host: "100.64.1.2", port: 49831)
    )
    let irohRoute = try CmxAttachRoute(
        id: "iroh",
        kind: .iroh,
        endpoint: .peer(id: canonicalEndpointID, relayHint: nil, directAddrs: [], relayURL: nil)
    )

    let tailscaleTransport = try factory.makeTransport(for: tailscaleRoute)
    let irohTransport = try factory.makeTransport(for: irohRoute)

    #expect(factory.supportedKinds == [.tailscale, .iroh])
    #expect((tailscaleTransport as? TaggedTransport)?.tag == "tailscale-tcp")
    #expect((irohTransport as? TaggedTransport)?.tag == "iroh-peer")
}

@Test func routeTransportFactoryRejectsDuplicateRegistrations() throws {
    #expect(throws: CmxRouteTransportFactoryError.duplicateRouteKind(.tailscale)) {
        _ = try CmxRouteTransportFactory([
            CmxRouteTransportFactoryRegistration(
                kind: .tailscale,
                factory: TaggedTransportFactory(tag: "first")
            ),
            CmxRouteTransportFactoryRegistration(
                kind: .tailscale,
                factory: TaggedTransportFactory(tag: "second")
            ),
        ])
    }
}

@Test func routeTransportFactoryRejectsUnsupportedRouteKind() throws {
    let factory = try CmxRouteTransportFactory([
        CmxRouteTransportFactoryRegistration(
            kind: .tailscale,
            factory: TaggedTransportFactory(tag: "tailscale-tcp")
        ),
    ])
    let route = try CmxAttachRoute(
        id: "iroh",
        kind: .iroh,
        endpoint: .peer(id: canonicalEndpointID, relayHint: nil, directAddrs: [], relayURL: nil)
    )

    #expect(throws: CmxRouteTransportFactoryError.unsupportedRouteKind(.iroh)) {
        _ = try factory.makeTransport(for: route)
    }
}

private struct TaggedTransportFactory: CmxByteTransportFactory {
    var tag: String

    func makeTransport(for route: CmxAttachRoute) throws -> any CmxByteTransport {
        TaggedTransport(tag: tag, route: route)
    }
}

private struct TaggedTransport: CmxByteTransport {
    var tag: String
    var route: CmxAttachRoute

    func connect() async throws {}

    func receive() async throws -> Data? {
        nil
    }

    func send(_ data: Data) async throws {}

    func close() async {}
}
