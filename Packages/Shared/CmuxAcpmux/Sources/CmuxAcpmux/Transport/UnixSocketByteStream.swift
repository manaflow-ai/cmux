public import CmuxConversation
public import Foundation
import Network
import os

/// A ``ConversationByteStream`` over a Unix domain socket (acpmux on this Mac).
public actor UnixSocketByteStream: ConversationByteStream {
    private let connection: NWConnection
    private var closed = false

    private init(connection: NWConnection) {
        self.connection = connection
    }

    /// Connects to `path`.
    /// - Parameters:
    ///   - path: The socket path.
    ///   - timeout: How long to wait for the connection.
    /// - Returns: The connected stream.
    /// - Throws: ``ConversationBackendError/unreachable(_:)`` when it fails,
    ///   or ``ConversationBackendError/timedOut``.
    public static func connect(path: String, timeout: Duration = .seconds(2)) async throws -> UnixSocketByteStream {
        let c = NWConnection(to: .unix(path: path), using: .tcp)
        let queue = DispatchQueue(label: "dev.cmux.acpmux.socket")
        // Several Network.framework callbacks and the deadline race to finish
        // the connect; the flag lets exactly one of them resume.
        let resumed = OSAllocatedUnfairLock(initialState: false)
        let claim: @Sendable () -> Bool = { resumed.withLock { done in defer { done = true }; return !done } }
        try await withCheckedThrowingContinuation { (k: CheckedContinuation<Void, any Error>) in
            c.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if claim() { k.resume() }
                case let .failed(e), let .waiting(e):
                    if claim() {
                        c.cancel()
                        k.resume(throwing: ConversationBackendError.unreachable("\(path): \(e)"))
                    }
                case .cancelled:
                    if claim() { k.resume(throwing: ConversationBackendError.unreachable("\(path): cancelled")) }
                default:
                    break
                }
            }
            c.start(queue: queue)
            Task {
                try? await Task.sleep(for: timeout)
                if claim() {
                    c.cancel()
                    k.resume(throwing: ConversationBackendError.timedOut)
                }
            }
        }
        c.stateUpdateHandler = nil
        return UnixSocketByteStream(connection: c)
    }

    /// Reads up to `maximumBytes`; `nil` once the peer closed.
    /// - Parameter maximumBytes: The most bytes to return.
    /// - Returns: The bytes, or `nil` at end of stream.
    /// - Throws: A transport error.
    public func read(maximumBytes: Int) async throws -> Data? {
        if closed { return nil }
        let c = connection
        return try await withCheckedThrowingContinuation { k in
            c.receive(minimumIncompleteLength: 1, maximumLength: maximumBytes) { data, _, done, error in
                if let error {
                    k.resume(throwing: ConversationBackendError.unreachable("\(error)"))
                } else if let data, !data.isEmpty {
                    k.resume(returning: data)
                } else if done {
                    k.resume(returning: nil)
                } else {
                    k.resume(returning: Data())
                }
            }
        }
    }

    /// Writes all of `data`.
    /// - Parameter data: The bytes.
    /// - Throws: A transport error.
    public func write(_ data: Data) async throws {
        let c = connection
        try await withCheckedThrowingContinuation { (k: CheckedContinuation<Void, any Error>) in
            c.send(content: data, completion: .contentProcessed { error in
                if let error {
                    k.resume(throwing: ConversationBackendError.unreachable("\(error)"))
                } else {
                    k.resume()
                }
            })
        }
    }

    /// Closes the socket.
    public func close() async {
        closed = true
        connection.cancel()
    }
}
