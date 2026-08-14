import Foundation
import Network
@testable import CmuxRemoteWorkspace

/// Loopback TCP client helper for talking to a bridge endpoint.
final class BridgeTestClient: @unchecked Sendable {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "bridge-test-client")
    private let lock = NSLock()
    private var received = Data()
    private var closed = false

    init(endpoint: RemotePTYBridgeServer.Endpoint) {
        connection = NWConnection(
            host: NWEndpoint.Host(endpoint.host),
            port: NWEndpoint.Port(rawValue: UInt16(endpoint.port))!,
            using: .tcp
        )
        connection.start(queue: queue)
        receiveLoop()
    }

    private func receiveLoop() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            self.lock.lock()
            if let data { self.received.append(data) }
            if isComplete || error != nil { self.closed = true }
            let done = self.closed
            self.lock.unlock()
            if !done { self.receiveLoop() }
        }
    }

    func send(_ data: Data) {
        connection.send(content: data, completion: .contentProcessed { _ in })
    }

    /// Sends data and returns a thread-safe pollable flag that flips once the
    /// network stack has accepted the entire payload without error. When the
    /// server pauses reads, assert this only after acks drain the input window.
    func sendTracked(_ data: Data) -> @Sendable () -> Bool {
        let lock = NSLock()
        // Guarded by `lock`; read and written only by the completion and returned closure.
        nonisolated(unsafe) var completed = false
        connection.send(content: data, completion: .contentProcessed { error in
            lock.lock()
            completed = (error == nil)
            lock.unlock()
        })
        return {
            lock.lock()
            defer { lock.unlock() }
            return completed
        }
    }

    /// Polls until `predicate` over the received bytes holds or the deadline
    /// passes (generous upper bound only; the happy path returns quickly).
    func waitForReceived(timeout: TimeInterval = 5.0, _ predicate: (Data, Bool) -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            lock.lock()
            let snapshot = received
            let isClosed = closed
            lock.unlock()
            if predicate(snapshot, isClosed) { return true }
            usleep(20_000)
        }
        return false
    }

    var isClosed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return closed
    }

    func cancel() {
        connection.cancel()
    }
}
