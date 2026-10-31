import CmuxNextCompat
import Darwin
public import Foundation

/// A line-delimited JSON connection to this app's acpmux whose server peer is checked on its
/// own descriptor before the first byte is written (cx-fcaq, cx-aocz review P1): the app's
/// person proof goes only to the acpmux this app runs, never to a listener that took the socket
/// path after an earlier probe. All state lives on one serial queue; callbacks run there and
/// callers hop to their own actor.
public nonisolated final class AcpmuxCheckedLine: @unchecked Sendable { // crash-allow: every mutable field is read and written only on `queue` (one serial queue)
    private let queue = DispatchQueue(label: "cmux.acpmux.checked-line")
    private let environment: AcpmuxEnvironment
    private var descriptor: Int32 = -1
    private var source: (any DispatchSourceRead)?
    private var buffer = Data()
    private var onLine: (@Sendable (Data) -> Void)?
    private var onClose: (@Sendable () -> Void)?
    private var closed = false
    /// Mirrors "connected, checked and not closed" for ``personProof(nonce:connection:)``, which
    /// main-actor callers make: reading it must not wait for `queue`, where a send to a peer
    /// that stopped reading can sit until its send timeout (``sendTimeoutSeconds``).
    private let isCheckedOpen = Atomic<Bool>(false)
    /// Set by ``cancel()`` at once, on the caller's thread, before the queue gets to its close: a gated
    /// write still queued then is never written (it checks this under the same lock, held through its
    /// write, so once ``cancel()`` returns no gated write starts).
    private let cancelled = Mutex(false)
    /// Largest line accepted.
    static let maxLine = 16 * 1024 * 1024
    /// The longest one send may block when acpmux stops reading (`SO_SNDTIMEO`); the connection
    /// then ends, so nothing waits on a full socket for good.
    static let sendTimeoutSeconds = 5

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
            var timeout = timeval(tv_sec: Self.sendTimeoutSeconds, tv_usec: 0)
            _ = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            isCheckedOpen.store(true, ordering: .releasing)
            let reader = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            reader.setEventHandler { [weak self] in self?.readable() }
            reader.setCancelHandler { Darwin.close(fd) }
            source = reader
            reader.resume()
            write(send)
        }
    }

    /// The person proof for this connection's challenge (acpmux `hub/person.rs`, transport unix),
    /// made only here so a proof exists only for a connection whose server peer was checked.
    /// Nil before the check passed, or when this app holds no key for this daemon. The key itself
    /// never leaves this process.
    public func personProof(nonce: String, connection: String) -> String? {
        guard isCheckedOpen.load(ordering: .acquiring) else { return nil }
        return AcpmuxPersonKey.proof(socketPath: environment.socketPath, transport: .unix, nonce: nonce,
                                     connection: connection)
    }

    /// Sends another request on the live connection.
    public func send(_ data: Data) {
        queue.async { [self] in write(data) }
    }

    /// Runs `work` on the line's queue, in order with its writes (tests hold the queue with it).
    func enqueue(_ work: @escaping @Sendable () -> Void) {
        queue.async(execute: work)
    }

    /// Sends `data` only through `gate`, on this queue right before the bytes go out: the gate runs the
    /// write (holding whatever makes its answer final) or refuses it, and a refused one closes the
    /// connection, so its request answers nil (a consent grant whose ticket went stale is never sent).
    /// A line cancelled meanwhile (closed, timed out) writes nothing either, even though its close is
    /// queued behind this.
    public func send(_ data: Data, through gate: @escaping @Sendable (() -> Void) -> Bool) {
        queue.async { [self] in
            let sent = cancelled.withLock { cancelled in !cancelled && gate { self.write(data) } }
            if !sent { finish() }
        }
    }

    /// Closes the connection. A gated write still queued is never written from the moment this returns
    /// (``send(_:through:)``); the close itself runs on the queue.
    public func cancel() {
        cancelled.withLock { $0 = true }
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
            let sent = data.withUnsafeBytes { bytes -> Int in
                guard let base = bytes.baseAddress else { return -1 }
                return Darwin.send(descriptor, base + offset, data.count - offset, 0)
            }
            if sent < 0, errno == EINTR { continue }
            guard sent > 0 else { return finish() }
            offset += sent
        }
    }

    private func readable() {
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        let count = Darwin.recv(descriptor, &chunk, chunk.count, 0)
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
        isCheckedOpen.store(false, ordering: .releasing)
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
