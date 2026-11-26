import Foundation
import Network

/// A byte stream to an RFB server. `NetworkRFBTransport` is TCP; an app can
/// supply another carrier (a tunnel, a test pipe).
public protocol RFBTransport: AnyObject, Sendable {
    /// Connects; returns when bytes can flow.
    func open() async throws
    /// The next bytes from the server, at least one. Throws
    /// `RFBError.connectionClosed` at the end of the stream.
    func receive() async throws -> [UInt8]
    /// Queues bytes in call order.
    func send(_ bytes: [UInt8]) async throws
    /// Closes the stream; pending reads throw.
    func close()
}

/// TCP through Network.framework, Nagle off (input events go out at once).
public final class NetworkRFBTransport: RFBTransport {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "cmux.vnc.transport", qos: .userInitiated)
    private let lifecycle = TransportLifecycle()

    public init(host: String, port: UInt16) {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.connectionTimeout = 15
        let parameters = NWParameters(tls: nil, tcp: tcp)
        connection = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port) ?? 5900, using: parameters)
    }

    public func open() async throws {
        let connection = self.connection
        let lifecycle = self.lifecycle
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                // A close (or cancellation) before this point fails the open at once:
                // a connection cancelled before it starts never reports a state.
                guard lifecycle.beginOpen(continuation) else { return }
                connection.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        lifecycle.finishOpen(nil)
                    case let .waiting(error), let .failed(error):
                        lifecycle.finishOpen(RFBError.transport(error.localizedDescription))
                        connection.cancel()
                    case .cancelled:
                        lifecycle.finishOpen(RFBError.connectionClosed)
                    default:
                        break
                    }
                }
                connection.start(queue: queue)
            }
        } onCancel: {
            lifecycle.close()
            connection.cancel()
        }
    }

    public func receive() async throws -> [UInt8] {
        let connection = self.connection
        return try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 18) { data, _, isComplete, error in
                if let data, !data.isEmpty {
                    continuation.resume(returning: [UInt8](data))
                } else if let error {
                    continuation.resume(throwing: RFBError.transport(error.localizedDescription))
                } else if isComplete {
                    continuation.resume(throwing: RFBError.connectionClosed)
                } else {
                    continuation.resume(returning: [])
                }
            }
        }
    }

    public func send(_ bytes: [UInt8]) async throws {
        guard !bytes.isEmpty else { return }
        let connection = self.connection
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            connection.send(content: Data(bytes), completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: RFBError.transport(error.localizedDescription))
                } else {
                    continuation.resume()
                }
            })
        }
    }

    public func close() {
        lifecycle.close()
        connection.cancel()
    }
}

/// Whether the transport was closed, and the open waiting for the
/// connection: resumed exactly once, by the connection state or by a close.
// crash-allow: `closed` and `opening` are read and written only while `lock` is held; the continuation resumes outside it, once.
final class TransportLifecycle: @unchecked Sendable {
    private let lock = NSLock()
    private var closed = false
    private var opening: CheckedContinuation<Void, any Error>?

    /// False (and the continuation already failed) when closed.
    func beginOpen(_ continuation: CheckedContinuation<Void, any Error>) -> Bool {
        lock.lock()
        guard !closed else {
            lock.unlock()
            continuation.resume(throwing: RFBError.connectionClosed)
            return false
        }
        opening = continuation
        lock.unlock()
        return true
    }

    func finishOpen(_ error: (any Error)?) {
        lock.lock()
        let continuation = opening
        opening = nil
        lock.unlock()
        if let error { continuation?.resume(throwing: error) } else { continuation?.resume() }
    }

    func close() {
        lock.lock()
        closed = true
        lock.unlock()
        finishOpen(RFBError.connectionClosed)
    }
}
