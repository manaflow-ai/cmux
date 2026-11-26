import CMUXMobileCore
import Foundation
@preconcurrency import Network
import Testing
@testable import CmuxMobileTransport

@Test func networkTransportFactoryRejectsNonNetworkRouteKind() throws {
    let route = try CmxAttachRoute(
        id: "iroh",
        kind: .iroh,
        endpoint: .peer(
            id: String(repeating: "e", count: 64),
            relayHint: nil,
            directAddrs: [],
            relayURL: nil
        )
    )

    #expect(throws: CmxNetworkByteTransportError.unsupportedRouteKind(.iroh)) {
        _ = try CmxNetworkByteTransportFactory().makeTransport(for: route)
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

@Test func acceptedNetworkTransportUsesTheSharedByteContract() async throws {
    let listener = try AcceptedConnectionListener()
    let port = try await listener.start()
    defer { listener.stop() }
    let client = try CmxNetworkByteTransport(host: "127.0.0.1", port: Int(port))
    let clientConnect = Task { try await client.connect() }
    let acceptedConnection = try await listener.nextConnection()
    let server = CmxNetworkByteTransport(acceptedConnection: acceptedConnection)

    do {
        try await server.connect()
        try await clientConnect.value
        try await client.send(Data("request".utf8))
        #expect(try await server.receive() == Data("request".utf8))
        try await server.send(Data("response".utf8))
        #expect(try await client.receive() == Data("response".utf8))
    } catch {
        clientConnect.cancel()
        await client.close()
        await server.close()
        throw error
    }
    await client.close()
    await server.close()
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

@Test func networkTransportFailsConnectFastWhenNothingListens() async throws {
    // Find a loopback port with no listener by briefly binding one and
    // releasing it. Dialing it gets an immediate TCP RST, which
    // Network.framework surfaces as `.waiting(ECONNREFUSED)` (it retries by
    // design, `.failed` is reserved for unrecoverable errors). The transport
    // must treat that definitive answer as a connect failure NOW: parking in
    // `.waiting` until the connect timeout is what added a whole request
    // timeout to scan-to-pair latency whenever a dead route sorted first.
    let server = try NetworkEchoServer(response: Data())
    let port = try await server.start()
    // Deterministically wait for the listener to reach `.cancelled` (the OS has
    // released the port) instead of guessing with a fixed sleep, which could
    // dial before teardown completed and see a half-open socket rather than the
    // immediate refusal this test asserts.
    await server.stopAndWaitForCancellation()

    let transport = try CmxNetworkByteTransport(
        host: "127.0.0.1",
        port: Int(port),
        connectTimeoutNanoseconds: 5_000_000_000
    )
    do {
        try await transport.connect()
        Issue.record("connect() to a closed port should fail")
    } catch let error as CmxNetworkByteTransportError {
        // The definitive refusal must surface as the classified connect
        // failure, not as `.connectionTimedOut` after the full deadline.
        guard case let .connectionFailed(_, kind) = error else {
            Issue.record("expected connectionFailed, got \(error)")
            await transport.close()
            return
        }
        #expect(kind == .connectionRefused)
    }
    await transport.close()
}

private final class NetworkEchoServer: @unchecked Sendable {
    // Wraps NWListener; every mutation happens on `queue`.
    private let listener: NWListener
    private let response: Data
    private let queue = DispatchQueue(label: "dev.cmux.mobile.network-echo-server")
    private var readyContinuation: CheckedContinuation<UInt16, Error>?
    private var cancelledContinuation: CheckedContinuation<Void, Never>?
    private var didCancel = false
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
            self.beginCancel()
        }
    }

    /// Cancels the listener and suspends until it reaches `.cancelled`, so callers
    /// know the OS has released the bound port before they dial it.
    func stopAndWaitForCancellation() async {
        await withCheckedContinuation { continuation in
            queue.async {
                if self.didCancel {
                    continuation.resume()
                    return
                }
                self.cancelledContinuation = continuation
                self.beginCancel()
            }
        }
    }

    private func beginCancel() {
        listener.cancel()
        for connection in connections {
            connection.cancel()
        }
        connections.removeAll()
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
            didCancel = true
            readyContinuation?.resume(throwing: CancellationError())
            readyContinuation = nil
            cancelledContinuation?.resume()
            cancelledContinuation = nil
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

private final class AcceptedConnectionListener: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "dev.cmux.mobile.accepted-connection-listener")
    private var readyContinuation: CheckedContinuation<UInt16, any Error>?
    private var connectionContinuation: CheckedContinuation<NWConnection, any Error>?
    private var pendingConnection: NWConnection?

    init() throws {
        listener = try NWListener(using: .tcp, on: .any)
    }

    func start() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                self.readyContinuation = continuation
                self.listener.stateUpdateHandler = { [weak self] state in
                    self?.handleState(state)
                }
                self.listener.newConnectionHandler = { [weak self] connection in
                    self?.accept(connection)
                }
                self.listener.start(queue: self.queue)
            }
        }
    }

    func nextConnection() async throws -> NWConnection {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                if let pendingConnection = self.pendingConnection {
                    self.pendingConnection = nil
                    continuation.resume(returning: pendingConnection)
                } else {
                    self.connectionContinuation = continuation
                }
            }
        }
    }

    func stop() {
        queue.async {
            self.listener.cancel()
            self.pendingConnection?.cancel()
            self.pendingConnection = nil
            self.connectionContinuation?.resume(throwing: CancellationError())
            self.connectionContinuation = nil
        }
    }

    private func accept(_ connection: NWConnection) {
        if let continuation = connectionContinuation {
            connectionContinuation = nil
            continuation.resume(returning: connection)
        } else {
            pendingConnection?.cancel()
            pendingConnection = connection
        }
    }

    private func handleState(_ state: NWListener.State) {
        switch state {
        case .ready:
            guard let port = listener.port?.rawValue else {
                readyContinuation?.resume(
                    throwing: CmxNetworkByteTransportError.invalidPort(0)
                )
                readyContinuation = nil
                return
            }
            readyContinuation?.resume(returning: port)
            readyContinuation = nil
        case let .failed(error):
            readyContinuation?.resume(throwing: error)
            readyContinuation = nil
            connectionContinuation?.resume(throwing: error)
            connectionContinuation = nil
        case .cancelled:
            readyContinuation?.resume(throwing: CancellationError())
            readyContinuation = nil
            connectionContinuation?.resume(throwing: CancellationError())
            connectionContinuation = nil
        case .setup, .waiting:
            break
        @unknown default:
            break
        }
    }
}
