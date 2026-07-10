import Foundation
import Testing
@testable import CMUXMobileCore

@Test func attachTicketChoosesFirstSupportedRouteByPriority() throws {
    let iroh = try CmxAttachRoute(
        id: "iroh",
        kind: .iroh,
        endpoint: .peer(
            id: "node-1",
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
        expiresAt: now.addingTimeInterval(-1)
    )
    let tailscale = try CmxIrohPathHint(
        kind: .directAddress,
        value: "100.64.1.2:49152",
        source: .tailscale,
        privacyScope: .privateNetwork,
        expiresAt: now.addingTimeInterval(60)
    )
    let customVPN = try CmxIrohPathHint(
        kind: .directAddress,
        value: "10.10.0.8:49152",
        source: .customVPN,
        privacyScope: .privateNetwork,
        expiresAt: now.addingTimeInterval(30)
    )
    let endpoint = CmxAttachEndpoint.peer(
        identity: CmxIrohPeerIdentity(endpointID: "endpoint-1"),
        pathHints: [tailscale, expiredLAN, relay, customVPN]
    )

    #expect(endpoint.irohPeerIdentity == CmxIrohPeerIdentity(endpointID: "endpoint-1"))
    #expect(tailscale.use == .fallbackOnly)
    #expect(expiredLAN.use == .fallbackOnly)
    #expect(customVPN.use == .fallbackOnly)
    #expect(relay.use == .primary)
    #expect(endpoint.usableIrohPathHints(at: now) == [relay, tailscale, customVPN])
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
    #expect(throws: CmxIrohPathHintError.missingPrivateHintExpiry) {
        _ = try CmxIrohPathHint(
            kind: .directAddress,
            value: "192.168.1.20:49152",
            source: .lan,
            privacyScope: .localNetwork
        )
    }
    #expect(throws: CmxIrohPathHintError.missingPrivateHintExpiry) {
        _ = try CmxIrohPathHint(
            kind: .directAddress,
            value: "10.0.0.4:49152",
            source: .native,
            privacyScope: .privateNetwork
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
    let endpointID = CmxIrohPeerIdentity(endpointID: "endpoint-1")

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
        expiresAt: expiry
    )
    let ipv6 = try CmxIrohPathHint(
        kind: .directAddress,
        value: "[fd7a:115c:a1e0::1]:49152",
        source: .tailscale,
        privacyScope: .privateNetwork,
        expiresAt: expiry
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
                expiresAt: expiry
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
        "[fd00:ec2::254]:49152",
    ] {
        #expect(throws: CmxIrohPathHintError.forbiddenDirectAddress) {
            _ = try CmxIrohPathHint(
                kind: .directAddress,
                value: forbidden,
                source: .native,
                privacyScope: .localNetwork,
                expiresAt: expiry
            )
        }
    }

    let legitimateLinkLocal = try CmxIrohPathHint(
        kind: .directAddress,
        value: "169.254.42.7:49152",
        source: .lan,
        privacyScope: .localNetwork,
        expiresAt: expiry
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
        "[fe80::1]:49152",
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
        expiresAt: expiry
    )
    _ = try CmxIrohPathHint(
        kind: .directAddress,
        value: "169.254.42.7:49152",
        source: .lan,
        privacyScope: .localNetwork,
        expiresAt: expiry
    )
    _ = try CmxIrohPathHint(
        kind: .directAddress,
        value: "[fd7a:115c:a1e0::1]:49152",
        source: .tailscale,
        privacyScope: .privateNetwork,
        expiresAt: expiry
    )
    _ = try CmxIrohPathHint(
        kind: .directAddress,
        value: "[fe80::1]:49152",
        source: .lan,
        privacyScope: .localNetwork,
        expiresAt: expiry
    )
    _ = try CmxIrohPathHint(
        kind: .directAddress,
        value: "192.0.2.4:49152",
        source: .customVPN,
        privacyScope: .privateNetwork,
        expiresAt: expiry
    )
    _ = try CmxIrohPathHint(
        kind: .directAddress,
        value: "[2001:db8::1]:49152",
        source: .customVPN,
        privacyScope: .privateNetwork,
        expiresAt: expiry
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
}

@Test func networkProfileIdentityDisambiguatesOverlappingPrivateNetworks() throws {
    let expiry = Date(timeIntervalSince1970: 2_000_000_000)
    let siteA = try CmxIrohPathHint(
        kind: .directAddress,
        value: "10.0.0.4:49152",
        source: .customVPN,
        privacyScope: .privateNetwork,
        expiresAt: expiry,
        networkProfileID: "corp-vpn:site-a"
    )
    let siteB = try CmxIrohPathHint(
        kind: .directAddress,
        value: "10.0.0.4:49152",
        source: .customVPN,
        privacyScope: .privateNetwork,
        expiresAt: expiry,
        networkProfileID: "corp-vpn:site-b"
    )

    #expect(siteA != siteB)
    #expect(siteA.networkProfileID == "corp-vpn:site-a")
    #expect(siteB.networkProfileID == "corp-vpn:site-b")

    let endpoint = CmxAttachEndpoint.peer(
        identity: CmxIrohPeerIdentity(endpointID: "endpoint-1"),
        pathHints: [siteA, siteB]
    )
    #expect(endpoint.usableIrohPathHints(
        at: Date(timeIntervalSince1970: 1_999_999_999),
        activeNetworkProfileIDs: ["corp-vpn:site-a"]
    ) == [siteA])
    #expect(endpoint.usableIrohPathHints(
        at: Date(timeIntervalSince1970: 1_999_999_999)
    ).isEmpty)
}

@Test func providerAttributedIrohEndpointRoundTripsIdentityAndHintPolicy() throws {
    let expiry = Date(timeIntervalSince1970: 2_000_000_000)
    let endpoint = CmxAttachEndpoint.peer(
        identity: CmxIrohPeerIdentity(endpointID: "endpoint-1"),
        pathHints: [
            try CmxIrohPathHint(
                kind: .directAddress,
                value: "100.64.1.2:49152",
                source: .tailscale,
                privacyScope: .privateNetwork,
                expiresAt: expiry,
                networkProfileID: "tailnet:production"
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
                identity: CmxIrohPeerIdentity(endpointID: "node-1"),
                pathHints: [
                    try CmxIrohPathHint(
                        kind: .directAddress,
                        value: "100.64.1.2:49152",
                        source: .tailscale,
                        privacyScope: .privateNetwork,
                        expiresAt: Date(timeIntervalSince1970: 2_000_000_000),
                        networkProfileID: "tailnet:production"
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
        "id": "node-1",
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
    #expect(identity.endpointID == "node-1")
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
        "id": "node-1",
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
    #expect(identity.endpointID == "node-1")
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
        "id": "node-1",
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
    #expect(redecodedIdentity.endpointID == "node-1")
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
        "id": "node-1",
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
        endpoint: .peer(id: "node-1", relayHint: nil, directAddrs: [], relayURL: nil)
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
        endpoint: .peer(id: "node-1", relayHint: nil, directAddrs: [], relayURL: nil)
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
