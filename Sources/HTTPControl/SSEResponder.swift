import CmuxTerminalAccess
import Foundation
import Network

/// Streams Server-Sent Events back to an HTTP client over an
/// ``NWConnection``.
///
/// Frame shape per spec §9:
/// ```
/// id: <seq>
/// event: <name>
/// data: <json>
/// \n
/// ```
/// plus a heartbeat comment line (``": ping\n\n"``) every
/// ``heartbeatSeconds`` seconds of write-quiescence, and the synthetic
/// gap comment (``": gap from=<a> to=<b>\n\n"``) the route emits on a
/// resume below the per-subscriber ring's oldest seq (D6).
///
/// The responder is thin on purpose — it owns header serialisation,
/// frame encoding, and "the last bytes I wrote was at time T" — and
/// the route owns subscription wiring, ring drains, and the heartbeat
/// timer.
///
/// Writes are funnelled through a single ``NWConnection`` and the
/// continuation returned by ``NWConnection/send(content:completion:)``
/// is bridged to `async` via `withCheckedThrowingContinuation`. Errors
/// from `.contentProcessed` propagate out of the matching `emit*`
/// method so the route can tear the subscription down cleanly.
public final class SSEResponder: @unchecked Sendable {
    /// Underlying network connection; weakly referenced by the route's
    /// connection registry so token rotation can locate the responder.
    public let connection: NWConnection

    private let clock: any MonotonicClock
    /// Heartbeat interval in seconds — every `tick()` past this many
    /// seconds without a write emits the keep-alive comment.
    public let heartbeatSeconds: TimeInterval

    private let lock = NSLock()
    private var headersSent = false
    private var closed = false
    private var _lastWriteAt: Double

    /// Monotonic time (in seconds) of the most recent successful write.
    /// Used by the route's heartbeat scheduler to suppress redundant
    /// `: ping` comments after live events.
    public var lastWriteAt: Double {
        lock.lock(); defer { lock.unlock() }
        return _lastWriteAt
    }

    /// Creates a responder bound to `connection`.
    ///
    /// - Parameters:
    ///   - connection: Live ``NWConnection`` accepted by
    ///     ``HTTPControlServer``. The responder does not start the
    ///     connection (the server already did so before dispatch).
    ///   - clock: Monotonic clock used for the heartbeat-quiescence
    ///     check; defaults to ``SystemMonotonicClock``.
    ///   - heartbeatSeconds: Interval between automatic `: ping`
    ///     comments when ``tick()`` runs; defaults to 20s per spec.
    public init(
        connection: NWConnection,
        clock: any MonotonicClock = SystemMonotonicClock(),
        heartbeatSeconds: TimeInterval = 20
    ) {
        self.connection = connection
        self.clock = clock
        self.heartbeatSeconds = heartbeatSeconds
        self._lastWriteAt = clock.now()
    }

    /// Sends the SSE response head:
    /// ```
    /// HTTP/1.1 200 OK
    /// Content-Type: text/event-stream
    /// Cache-Control: no-cache
    /// Connection: keep-alive
    /// X-Accel-Buffering: no
    ///
    /// ```
    /// Subsequent calls are no-ops so accidental double-send cannot
    /// corrupt the wire.
    public func writeHeaders() async throws {
        lock.lock()
        if headersSent {
            lock.unlock()
            return
        }
        headersSent = true
        lock.unlock()
        let head = "HTTP/1.1 200 OK\r\n" +
                   "Content-Type: text/event-stream\r\n" +
                   "Cache-Control: no-cache\r\n" +
                   "Connection: keep-alive\r\n" +
                   "X-Accel-Buffering: no\r\n" +
                   "\r\n"
        try await sendRaw(Data(head.utf8))
    }

    /// Emits a single ``OutputEvent`` as an SSE frame. `seqOverride`
    /// lets the route emit a synthetic event id (currently unused; the
    /// frame id defaults to the event's embedded seq).
    public func emit(_ event: OutputEvent, seqOverride: UInt64? = nil) async throws {
        let (seq, name, payload): (UInt64, String, String)
        switch event {
        case .rawBytes(let data, let s):
            seq = seqOverride ?? s
            name = "output"
            payload = StreamPayloads.rawPayload(data)
        case .cellsSnapshot(let grid, let s):
            seq = seqOverride ?? s
            name = "screen"
            payload = StreamPayloads.cellsPayload(grid)
        case .gap(let s):
            seq = seqOverride ?? s
            name = "gap"
            payload = "{}"
        }
        // SSE frames terminate with a blank line (\n\n). Per spec §9
        // we use LF, not CRLF, inside the SSE body itself; the HTTP
        // head above is CRLF-terminated.
        let frame = "id: \(seq)\nevent: \(name)\ndata: \(payload)\n\n"
        try await sendRaw(Data(frame.utf8))
    }

    /// D6 synthetic gap comment for a resume below the ring's oldest
    /// seq. Comments start with `:` so SSE clients ignore them by
    /// default; the route still emits one so a debugger can see the
    /// gap on the wire.
    public func emitGapComment(from requested: UInt64, to oldest: UInt64) async throws {
        try await sendRaw(Data(": gap from=\(requested) to=\(oldest)\n\n".utf8))
    }

    /// Writes the keep-alive ``": ping\n\n"`` comment.
    public func emitHeartbeat() async throws {
        try await sendRaw(Data(": ping\n\n".utf8))
    }

    /// Emits the terminal ``event: end`` frame the route uses to signal
    /// surface-close / token rotation / cap teardown. Idempotent — once
    /// the responder has emitted an end frame, subsequent calls are
    /// no-ops.
    public func emitEnd() async throws {
        lock.lock()
        if closed {
            lock.unlock()
            return
        }
        lock.unlock()
        try await sendRaw(Data("event: end\ndata: {}\n\n".utf8))
    }

    /// Tears the underlying connection down and marks the responder
    /// closed. Safe to call from multiple cancel paths.
    public func close() async {
        lock.lock()
        if closed {
            lock.unlock()
            return
        }
        closed = true
        lock.unlock()
        connection.cancel()
    }

    /// Returns true when ``close()`` (or a fatal write error) has
    /// finished tearing the connection down.
    public var isClosed: Bool {
        lock.lock(); defer { lock.unlock() }
        return closed
    }

    // MARK: - Internal write plumbing

    /// Bridges ``NWConnection/send(content:completion:)`` to async/await
    /// via ``withCheckedThrowingContinuation``. The send completion is
    /// the only way to learn about pipe-closed / write errors on a
    /// half-streamed connection, so the responder reflects them back
    /// to the caller so the route can drop the subscription.
    private func sendRaw(_ data: Data) async throws {
        lock.lock()
        if closed {
            lock.unlock()
            throw TerminalAccessError.ghosttyError("sse connection closed")
        }
        lock.unlock()
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    cont.resume(throwing: error)
                } else {
                    cont.resume(returning: ())
                }
            })
        }
        lock.lock()
        _lastWriteAt = clock.now()
        lock.unlock()
    }
}
