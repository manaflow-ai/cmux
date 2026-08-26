import Foundation
import Testing
@testable import CMUXMobileCore

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
        kind: .websocket,
        endpoint: .hostPort(host: "100.64.1.2", port: 49831)
    )) {
        _ = try CmxAttachRoute(
            id: "bad",
            kind: .websocket,
            endpoint: .hostPort(host: "100.64.1.2", port: 49831)
        )
    }
}

@Test func attachRouteDecoderRejectsMismatchedEndpointKind() throws {
    let data = Data("""
    {
      "id": "bad",
      "kind": "websocket",
      "endpoint": {
        "type": "host_port",
        "host": "100.64.1.2",
        "port": 49831
      },
      "priority": 0
    }
    """.utf8)

    #expect(throws: CmxAttachRouteError.endpointMismatch(
        kind: .websocket,
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

@Test func attachTicketDecoderDropsUnknownRouteKindAndKeepsTailscale() throws {
    // Peers running other releases still publish routes with kinds this build
    // does not understand (an old Mac's `iroh` peer route, or a future kind).
    // The unknown element is dropped; the tailscale route survives.
    let data = Data("""
    {
      "version": 1,
      "workspaceID": "workspace-1",
      "terminalID": null,
      "macDeviceID": "mac-1",
      "macDisplayName": null,
      "routes": [
        {
          "id": "iroh",
          "kind": "iroh",
          "endpoint": {
            "type": "peer",
            "id": "\(String(repeating: "a", count: 64))",
            "direct_addrs": ["192.168.1.20:49152"],
            "relay_url": "https://relay.example.test"
          },
          "priority": 0
        },
        {
          "id": "tailscale",
          "kind": "tailscale",
          "endpoint": {
            "type": "host_port",
            "host": "100.64.1.2",
            "port": 49831
          },
          "priority": 10
        }
      ],
      "expiresAt": "2033-05-18T03:33:20Z"
    }
    """.utf8)
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601

    let ticket = try decoder.decode(CmxAttachTicket.self, from: data)

    #expect(ticket.routes.map(\.id) == ["tailscale"])
    #expect(ticket.routes.first?.kind == .tailscale)
    #expect(ticket.routes.first?.endpoint == .hostPort(host: "100.64.1.2", port: 49831))
}

@Test func attachTicketDecoderDropsUndecodableEndpointShapeAndKeepsRest() throws {
    // A known kind with an endpoint shape this build cannot read (or a
    // structurally invalid route) is dropped per element, never failing the
    // surrounding ticket.
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
          "kind": "tailscale",
          "endpoint": {
            "type": "peer",
            "id": "\(String(repeating: "a", count: 64))"
          },
          "priority": 0
        },
        "not-even-an-object",
        {
          "id": "tailscale",
          "kind": "tailscale",
          "endpoint": {
            "type": "host_port",
            "host": "100.64.1.2",
            "port": 49831
          },
          "priority": 10
        }
      ]
    }
    """.utf8)
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601

    let ticket = try decoder.decode(CmxAttachTicket.self, from: data)

    #expect(ticket.routes.map(\.id) == ["tailscale"])
}

@Test func attachTicketDecoderRejectsTicketWhoseRoutesAreAllUnknown() throws {
    // When every route is dropped nothing remains to dial; the ticket fails
    // structurally with `noRoutes` instead of decoding into a useless value.
    let data = Data("""
    {
      "version": 1,
      "workspaceID": "workspace-1",
      "terminalID": null,
      "macDeviceID": "mac-1",
      "macDisplayName": null,
      "routes": [
        {
          "id": "iroh",
          "kind": "iroh",
          "endpoint": {
            "type": "peer",
            "id": "\(String(repeating: "a", count: 64))"
          },
          "priority": 0
        }
      ]
    }
    """.utf8)
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601

    #expect(throws: CmxAttachTicketError.noRoutes) {
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
            kind: .websocket,
            factory: TaggedTransportFactory(tag: "websocket-url")
        ),
    ])
    let tailscaleRoute = try CmxAttachRoute(
        id: "tailscale",
        kind: .tailscale,
        endpoint: .hostPort(host: "100.64.1.2", port: 49831)
    )
    let websocketRoute = try CmxAttachRoute(
        id: "websocket",
        kind: .websocket,
        endpoint: .url("wss://cmux.example.test/terminal")
    )

    let tailscaleTransport = try factory.makeTransport(for: tailscaleRoute)
    let websocketTransport = try factory.makeTransport(for: websocketRoute)

    #expect(factory.supportedKinds == [.tailscale, .websocket])
    #expect((tailscaleTransport as? TaggedTransport)?.tag == "tailscale-tcp")
    #expect((websocketTransport as? TaggedTransport)?.tag == "websocket-url")
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
            kind: .tailscale,
            factory: RequestTaggedTransportFactory()
        ),
    ])
    let route = try CmxAttachRoute(
        id: "tailscale",
        kind: .tailscale,
        endpoint: .hostPort(host: "100.64.1.2", port: 49831)
    )
    let request = CmxByteTransportRequest(
        route: route,
        expectedPeerDeviceID: "mac-device-a",
        authorizationMode: .stackBearer
    )

    let transport = try factory.makeTransport(for: request)

    #expect((transport as? TaggedTransport)?.tag == "mac-device-a:stack")
}

@Test func routeTransportFactoryRejectsUnsupportedRouteKind() throws {
    let factory = try CmxRouteTransportFactory([
        CmxRouteTransportFactoryRegistration(
            kind: .tailscale,
            factory: TaggedTransportFactory(tag: "tailscale-tcp")
        ),
    ])
    let route = try CmxAttachRoute(
        id: "websocket",
        kind: .websocket,
        endpoint: .url("wss://cmux.example.test/terminal")
    )

    #expect(throws: CmxRouteTransportFactoryError.unsupportedRouteKind(.websocket)) {
        _ = try factory.makeTransport(for: route)
    }
}
