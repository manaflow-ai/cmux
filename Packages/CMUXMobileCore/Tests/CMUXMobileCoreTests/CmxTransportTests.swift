import Foundation
@preconcurrency import Network
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

@Test func networkTransportFactoryBuildsHostPortTransportForSupportedRoute() throws {
    let route = try CmxAttachRoute(
        id: "tailscale",
        kind: .tailscale,
        endpoint: .hostPort(host: "100.64.1.2", port: 49831)
    )

    let transport = try CmxNetworkByteTransportFactory().makeTransport(for: route)

    #expect(transport is CmxNetworkByteTransport)
}

@Test func networkTransportFactoryRejectsNonNetworkRouteKind() throws {
    let route = try CmxAttachRoute(
        id: "iroh",
        kind: .iroh,
        endpoint: .peer(id: "node-1", relayHint: nil, directAddrs: [], relayURL: nil)
    )

    #expect(throws: CmxNetworkByteTransportError.unsupportedRouteKind(.iroh)) {
        _ = try CmxNetworkByteTransportFactory().makeTransport(for: route)
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

@Test func networkTransportExchangesBytesOverHostPortRoute() async throws {
    let server = try NetworkEchoServer(response: Data("pong".utf8))
    let port = try await server.start()
    defer { server.stop() }

    let route = try CmxAttachRoute(
        id: "loopback",
        kind: .debugLoopback,
        endpoint: .hostPort(host: "127.0.0.1", port: Int(port))
    )
    let transport = try CmxNetworkByteTransportFactory().makeTransport(for: route)

    do {
        try await transport.connect()
        try await transport.send(Data("ping".utf8))
        let response = try await transport.receive()
        await transport.close()

        #expect(response == Data("pong".utf8))
    } catch {
        await transport.close()
        throw error
    }
}

@Test func networkTransportCloseCompletesInFlightReceiveWithEndOfStream() async throws {
    let server = try NetworkEchoServer(response: Data("unused".utf8))
    let port = try await server.start()
    defer { server.stop() }

    let route = try CmxAttachRoute(
        id: "loopback",
        kind: .debugLoopback,
        endpoint: .hostPort(host: "127.0.0.1", port: Int(port))
    )
    let transport = try CmxNetworkByteTransportFactory().makeTransport(for: route)

    try await transport.connect()
    let receiveTask = Task {
        try await transport.receive()
    }
    await Task.yield()
    await transport.close()

    #expect(try await receiveTask.value == nil)
    #expect(try await transport.receive() == nil)
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

private final class NetworkEchoServer: @unchecked Sendable {
    private let listener: NWListener
    private let response: Data
    private let queue = DispatchQueue(label: "dev.cmux.mobile.network-echo-server")
    private var readyContinuation: CheckedContinuation<UInt16, Error>?
    private var connections: [NWConnection] = []

    init(response: Data) throws {
        listener = try NWListener(using: .tcp, on: .any)
        self.response = response
    }

    func start() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                self.readyContinuation = continuation
                self.listener.stateUpdateHandler = { [weak self] state in
                    self?.handleListenerState(state)
                }
                self.listener.newConnectionHandler = { [weak self] connection in
                    self?.accept(connection)
                }
                self.listener.start(queue: self.queue)
            }
        }
    }

    func stop() {
        queue.async {
            self.listener.cancel()
            for connection in self.connections {
                connection.cancel()
            }
            self.connections.removeAll()
        }
    }

    private func handleListenerState(_ state: NWListener.State) {
        switch state {
        case .ready:
            guard let port = listener.port?.rawValue else {
                readyContinuation?.resume(throwing: CmxNetworkByteTransportError.invalidPort(0))
                readyContinuation = nil
                return
            }
            readyContinuation?.resume(returning: port)
            readyContinuation = nil
        case let .failed(error):
            readyContinuation?.resume(throwing: error)
            readyContinuation = nil
        case .cancelled:
            readyContinuation?.resume(throwing: CancellationError())
            readyContinuation = nil
        case .setup, .waiting:
            break
        @unknown default:
            break
        }
    }

    private func accept(_ connection: NWConnection) {
        connections.append(connection)
        connection.start(queue: queue)
        receiveRequest(on: connection)
    }

    private func receiveRequest(on connection: NWConnection) {
        connection.receive(
            minimumIncompleteLength: 1,
            maximumLength: 64 * 1024
        ) { [weak self, weak connection] data, _, isComplete, error in
            guard let self, let connection else {
                return
            }
            if let data, !data.isEmpty {
                connection.send(
                    content: self.response,
                    contentContext: .defaultMessage,
                    isComplete: true,
                    completion: .contentProcessed { _ in
                        connection.cancel()
                    }
                )
                return
            }
            if isComplete || error != nil {
                connection.cancel()
                return
            }
            self.receiveRequest(on: connection)
        }
    }
}
