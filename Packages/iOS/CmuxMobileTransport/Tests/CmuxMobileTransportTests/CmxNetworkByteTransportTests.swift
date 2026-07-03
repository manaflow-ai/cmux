import CMUXMobileCore
import Foundation
@preconcurrency import Network
import Testing
@testable import CmuxMobileTransport

@Test func networkTransportFactoryBuildsHostPortTransportForSupportedRoute() throws {
    let route = try CmxAttachRoute(
        id: "tailscale",
        kind: .tailscale,
        endpoint: .hostPort(host: "100.64.1.2", port: 49831)
    )

    let transport = try CmxNetworkByteTransportFactory().makeTransport(for: route)

    #expect(transport is CmxNetworkByteTransport)
}

@Test func networkTransportFactoryBuildsManualHostTransportByDefault() throws {
    let route = try CmxAttachRoute(
        id: "manual_host",
        kind: .manualHost,
        endpoint: .hostPort(host: "studio-mac.local", port: 49831)
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
