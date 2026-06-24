import CMUXMobileCore
import Foundation
@preconcurrency import Network
import Testing
@testable import CmuxMobileTransport

@Test func pingReportsReachableWithLatencyForLiveListener() async throws {
    let listener = try PingTestListener()
    let port = try await listener.start()
    defer { listener.stop() }

    let route = try CmxAttachRoute(
        id: "loopback",
        kind: .debugLoopback,
        endpoint: .hostPort(host: "127.0.0.1", port: Int(port))
    )

    let result = await cmxPingRoute(route, timeoutNanoseconds: 5_000_000_000)

    guard case let .reachable(latency) = result else {
        Issue.record("expected .reachable, got \(result)")
        return
    }
    #expect(latency >= 0)
}

@Test func pingReportsRefusedWhenNothingListens() async throws {
    // Bind then release a port so the OS gives an immediate refusal on dial.
    let listener = try PingTestListener()
    let port = try await listener.start()
    await listener.stopAndWaitForCancellation()

    let route = try CmxAttachRoute(
        id: "loopback",
        kind: .debugLoopback,
        endpoint: .hostPort(host: "127.0.0.1", port: Int(port))
    )

    let result = await cmxPingRoute(route, timeoutNanoseconds: 5_000_000_000)

    #expect(result == .refused)
}

@Test func pingReportsUnsupportedRouteForNonHostPortEndpoint() async throws {
    let route = try CmxAttachRoute(
        id: "iroh",
        kind: .iroh,
        endpoint: .peer(id: "node-1", relayHint: nil, directAddrs: [], relayURL: nil)
    )

    let result = await cmxPingRoute(route)

    #expect(result == .unsupportedRoute)
}

/// Minimal TCP listener that accepts and silently holds connections, used to
/// prove a reachable address. (The byte-transport tests keep their own echo
/// server; ping only needs the connect to succeed.)
private final class PingTestListener: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "dev.cmux.mobile.ping-test-listener")
    private var readyContinuation: CheckedContinuation<UInt16, any Error>?
    private var cancelledContinuation: CheckedContinuation<Void, Never>?
    private var didCancel = false
    private var connections: [NWConnection] = []

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
                    guard let self else { return }
                    self.connections.append(connection)
                    connection.start(queue: self.queue)
                }
                self.listener.start(queue: self.queue)
            }
        }
    }

    func stop() {
        queue.async { self.beginCancel() }
    }

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
        for connection in connections { connection.cancel() }
        connections.removeAll()
    }

    private func handleState(_ state: NWListener.State) {
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
}
