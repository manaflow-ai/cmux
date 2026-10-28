import Darwin
public import Foundation

/// A line-delimited JSON connection to this app's acpmux whose server peer is checked on its
/// own descriptor before the first byte is written (cx-fcaq, cx-aocz review P1): the app's
/// person proof goes only to the acpmux this app runs, never to a listener that took the socket
/// path after an earlier probe. All state lives on one serial queue; callbacks run there and
/// callers hop to their own actor. The person proof is made and sent on that queue too
/// (``sendPersonProof(nonce:connection:request:refused:)``), so no caller waits for it.
public nonisolated final class AcpmuxCheckedLine: @unchecked Sendable { // crash-allow: every mutable field is read and written only on `queue` (one serial queue)
    private let queue = DispatchQueue(label: "cmux.acpmux.checked-line", qos: .userInitiated)
    private let environment: AcpmuxEnvironment
    private var descriptor: Int32 = -1
    private var source: (any DispatchSourceRead)?
    private var buffer = Data()
    private var onLine: (@Sendable (Data) -> Void)?
    private var onClose: (@Sendable () -> Void)?
    private var closed = false
    /// Largest line accepted.
    static let maxLine = 16 * 1024 * 1024

    public init(environment: AcpmuxEnvironment) {
        self.environment = environment
    }

    /// Connects, checks the server peer on this connection (own path only), then sends `send`.
    /// A refused or failed connect closes at once (`onClose`).
    public func start(send: Data, onLine: @escaping @Sendable (Data) -> Void, onClose: @escaping @Sendable () -> Void) {
        queue.async { [self] in
            self.onLine = onLine
            self.onClose = onClose
            do {
                descriptor = try AcpmuxServerPeer.connectChecked(socketPath: environment.socketPath,
                                                                 executable: environment.executable)
            } catch {
                return finish()
            }
            let fd = descriptor
            let reader = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            reader.setEventHandler { [weak self] in self?.readable() }
            reader.setCancelHandler { Darwin.close(fd) }
            source = reader
            reader.resume()
            write(send)
        }
    }

    /// Sends the person proof for this connection's challenge (acpmux `hub/person.rs`, transport unix)
    /// as the request `request` makes of it. The proof is made only on the line's queue, so a proof
    /// exists only for a connection whose server peer was checked, and it goes out before any request
    /// sent after this call. `refused` runs on the line's queue instead before the check passed, after
    /// the line closed, or when this app holds no key for this daemon. The caller never waits for the
    /// queue (a write there can wait for the socket), and the key itself never leaves this process.
    public func sendPersonProof(nonce: String, connection: String, request: @escaping @Sendable (String) -> Data,
                                refused: @escaping @Sendable () -> Void) {
        queue.async { [self] in
            guard descriptor >= 0, !closed,
                  let proof = AcpmuxPersonKey.proof(socketPath: environment.socketPath, transport: .unix, nonce: nonce,
                                                    connection: connection) else { return refused() }
            write(request(proof))
        }
    }

    /// Sends another request on the live connection.
    public func send(_ data: Data) {
        queue.async { [self] in write(data) }
    }

    public func cancel() {
        queue.async { [self] in
            onClose = nil
            onLine = nil
            finish()
        }
    }

    private func write(_ data: Data) {
        guard !closed, descriptor >= 0 else { return }
        var offset = 0
        while offset < data.count {
            // SAFETY: `bytes` is the data's contiguous storage, valid only inside this closure, which never lets a
            // pointer out; 0 <= offset < data.count (the loop's condition), so the send covers the data.count - offset
            // bytes from base + offset to the buffer's end.
            let sent = unsafe data.withUnsafeBytes { bytes -> Int in
                guard let base = unsafe bytes.baseAddress else { return -1 }
                return unsafe Darwin.send(descriptor, base + offset, data.count - offset, 0)
            }
            if sent < 0, errno == EINTR { continue }
            guard sent > 0 else { return finish() }
            offset += sent
        }
    }

    private func readable() {
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        // SAFETY: recv writes at most chunk.count bytes into the array's own storage, lent for the call.
        let count = unsafe Darwin.recv(descriptor, &chunk, chunk.count, 0)
        guard count > 0 else { return finish() }
        buffer.append(contentsOf: chunk[0..<count])
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = Data(buffer[buffer.startIndex..<newline])
            buffer.removeSubrange(buffer.startIndex...newline)
            if !line.isEmpty { onLine?(line) }
        }
        if buffer.count > Self.maxLine { finish() }
    }

    private func finish() {
        guard !closed else { return }
        closed = true
        // The read source closes the descriptor in its cancel handler, after
        // the source let go of it: closing here could close a descriptor
        // number that another connection already reused. Without a source
        // (a refused or failed start) this closes it.
        if let source {
            source.cancel()
            self.source = nil
        } else if descriptor >= 0 {
            Darwin.close(descriptor)
        }
        descriptor = -1
        let callback = onClose
        onClose = nil
        onLine = nil
        callback?()
    }
}
