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

@Test func routeTransportFactoryPreservesPeerIntentForRequestAwareTransports() throws {
    let factory = try CmxRouteTransportFactory([
        CmxRouteTransportFactoryRegistration(
            kind: .iroh,
            factory: RequestTaggedTransportFactory()
        ),
    ])
    let route = try CmxAttachRoute(
        id: "iroh",
        kind: .iroh,
        endpoint: .peer(id: canonicalEndpointID, relayHint: nil, directAddrs: [], relayURL: nil)
    )
    let request = CmxByteTransportRequest(
        route: route,
        expectedPeerDeviceID: "mac-device-a",
        authorizationMode: .transportAdmission
    )

    let transport = try factory.makeTransport(for: request)

    #expect((transport as? TaggedTransport)?.tag == "mac-device-a:admission")
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
