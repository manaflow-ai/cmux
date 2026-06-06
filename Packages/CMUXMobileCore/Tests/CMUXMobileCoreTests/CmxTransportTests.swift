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
                id: "node-1",
                relayHint: nil,
                directAddrs: ["100.64.1.2:49152"],
                relayURL: "https://relay.example.test"
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

@Test func attachTicketInitializerRejectsExpiredTicket() throws {
    let route = try CmxAttachRoute(
        id: "tailscale",
        kind: .tailscale,
        endpoint: .hostPort(host: "100.64.1.2", port: 49831)
    )

    #expect(throws: CmxAttachTicketError.expired) {
        _ = try CmxAttachTicket(
            workspaceID: "workspace-1",
            terminalID: nil,
            macDeviceID: "mac-1",
            macDisplayName: nil,
            routes: [route],
            expiresAt: Date(timeIntervalSince1970: 1_000)
        )
    }
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
    guard case let .peer(id, relayHint, directAddrs, relayURL) = route.endpoint else {
        Issue.record("Expected an Iroh peer endpoint")
        return
    }
    #expect(id == "node-1")
    #expect(relayHint == nil)
    #expect(directAddrs == ["192.168.1.20:49152", "100.64.1.2:49152"])
    #expect(relayURL == "https://relay.example.test")
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

    guard case let .peer(id, relayHint, directAddrs, relayURL) = route.endpoint else {
        Issue.record("Expected an Iroh peer endpoint")
        return
    }
    #expect(id == "node-1")
    #expect(relayHint == "legacy-relay")
    #expect(directAddrs.isEmpty)
    #expect(relayURL == nil)
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

@Test func attachTicketDecoderRejectsExpiredTicket() throws {
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

    #expect(throws: CmxAttachTicketError.expired) {
        _ = try decoder.decode(CmxAttachTicket.self, from: data)
    }
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
