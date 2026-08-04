public import Foundation
internal import Darwin
internal import Dispatch

/// A serialized, reusable client connection for newline-delimited Unix-socket
/// commands.
///
/// The connection validates the kernel-reported peer before every write. It
/// never retries a command after an I/O failure because the server may already
/// have performed the side effect before the response was lost.
public actor PersistentSocketLineConnection {
    private let worker: PersistentSocketLineConnectionWorker

    /// Creates a persistent line-oriented connection.
    ///
    /// - Parameters:
    ///   - transport: Socket syscall helpers.
    ///   - maximumResponseByteCount: Maximum buffered response size before the
    ///     connection fails closed.
    public init(
        transport: SocketTransport = SocketTransport(),
        maximumResponseByteCount: Int = 1_048_576
    ) {
        precondition(maximumResponseByteCount > 0)
        worker = PersistentSocketLineConnectionWorker(
            transport: transport,
            maximumResponseByteCount: maximumResponseByteCount,
            queue: DispatchQueue(
                label: "com.cmux.control-socket.persistent-line-io",
                qos: .userInitiated
            )
        )
    }

    /// Sends one command and reads its corresponding response line.
    ///
    /// Calls are serialized, so one connection can safely serve concurrent
    /// callers while preserving request/response order.
    public func command(
        _ command: String,
        at socketPath: String,
        timeout: TimeInterval,
        validatingPeer: @escaping @Sendable (pid_t?) -> Bool = { _ in true }
    ) async -> (response: String, peerProcessID: pid_t?)? {
        await worker.command(
            command,
            at: socketPath,
            timeout: timeout,
            validatingPeer: validatingPeer
        )
    }

    /// Closes the cached connection. The next command reconnects and
    /// revalidates the peer.
    public func invalidate() async {
        await worker.invalidate()
    }
}
