public import Foundation

/// What the renderer does with a frame.
public enum TerminalViewerAction: Hashable, Sendable {
    /// Replace the terminal state atomically (READY), at this generation.
    case restore(Data, generation: UInt32)
    /// Prepend history pages to the restored state.
    case prependHistory(Data)
    /// Parse these PTY bytes.
    case feed(Data)
    /// Send this `snapshot_request` on the channel. Bytes are dropped until the
    /// next READY; one request is in flight at a time. The caller reattaches
    /// if no READY arrives within its timeout.
    case requestSnapshot(SnapshotRequest)
    /// The host throttled the request: call `retryDue()` after this delay.
    case retryAfter(milliseconds: Int)
    /// The host's snapshot version differs from this viewer's: the host sends
    /// a byte replay instead, which the viewer now accepts without a snapshot.
    case versionMismatch(host: UInt16)
}

/// One viewer of one terminal under `terminal-snapshot-v1`. A value: feed it
/// frames in channel order, apply the returned actions in order.
public struct TerminalViewer: Sendable {
    public enum Mode: Hashable, Sendable {
        /// Waiting for the first READY, or for a READY after a gap or mismatch.
        case awaitingSnapshot
        /// Following live bytes after a restored READY.
        case live
        /// Snapshot versions differ: bytes are a replay, applied in offset order.
        case replay
    }

    /// The GHOSTSNP version this viewer restores and encodes.
    public let snapshotVersion: UInt16
    public private(set) var mode: Mode = .awaitingSnapshot
    public private(set) var generation: UInt32?
    /// The host offset the terminal state reflects.
    public private(set) var offset: UInt64?
    /// The offset of the restored READY; history pages must belong to it.
    public private(set) var snapshotOffset: UInt64?
    /// The request sent and not yet answered by a READY.
    public private(set) var inFlight: SnapshotRequest?

    private let terminal: String
    private let makeRequestID: @Sendable () -> String

    public init(terminal: String, snapshotVersion: UInt16,
                makeRequestID: @escaping @Sendable () -> String = { "snap-" + UUID().uuidString.lowercased() }) {
        self.terminal = terminal
        self.snapshotVersion = snapshotVersion
        self.makeRequestID = makeRequestID
    }

    /// An explicit request at attach (reason `attach`), when the viewer wants
    /// a snapshot before the host's first frame.
    public mutating func attachRequest() -> [TerminalViewerAction] {
        mode = .awaitingSnapshot
        return request(.attach)
    }

    /// The host answered `snapshot_throttled {retry_after_ms, request_id}`.
    /// A throttle naming another request (a late answer to an older one) is ignored.
    public mutating func throttled(retryAfterMilliseconds: Int, requestID: String) -> [TerminalViewerAction] {
        guard let inFlight, requestID == inFlight.requestID else { return [] }
        return [.retryAfter(milliseconds: max(0, retryAfterMilliseconds))]
    }

    /// The connection was replaced, or the in-flight request timed out: forget
    /// it (request ids are per connection), keep the terminal state, and wait
    /// for a READY. The next trigger or `attachRequest()` gets a new id.
    public mutating func connectionReset() {
        inFlight = nil
        mode = .awaitingSnapshot
    }

    /// The retry delay ended: resend the same request (same request_id) if
    /// no READY arrived meanwhile.
    public func retryDue() -> [TerminalViewerAction] {
        guard mode == .awaitingSnapshot, let inFlight else { return [] }
        return [.requestSnapshot(inFlight)]
    }

    /// - Parameter localDigest: SHA-256 of this viewer's own READY encoding,
    ///   or nil when it cannot encode one (then the digest check is skipped).
    public mutating func receive(_ frame: TerminalFrame, localDigest: () -> Data? = { nil }) -> [TerminalViewerAction] {
        if let version = frame.snapshotVersion, version != snapshotVersion {
            // A digest or history of another version is skipped; a READY switches to replay.
            guard frame.kind == .snapshotReady else { return [] }
            mode = .replay
            inFlight = nil
            offset = nil
            return [.versionMismatch(host: version)]
        }
        switch frame.kind {
        case .snapshotReady:
            mode = .live
            inFlight = nil
            generation = frame.generation
            offset = frame.offset
            snapshotOffset = frame.offset
            return [.restore(frame.payload, generation: frame.generation)]
        case .snapshotHistory:
            guard mode == .live, frame.generation == generation, frame.offset == snapshotOffset else { return [] }
            return [.prependHistory(frame.payload)]
        case .bytes:
            return mode == .replay ? replay(frame) : bytes(frame)
        case .digest:
            guard mode == .live, frame.generation == generation, frame.offset == offset,
                  let mine = localDigest(), mine != frame.payload else { return [] }
            return resync(.digestMismatch)
        }
    }

    private mutating func bytes(_ frame: TerminalFrame) -> [TerminalViewerAction] {
        // Before the first READY, and while a resync is pending, bytes wait for it.
        guard mode == .live, let generation, let offset else { return [] }
        // Older grid: stale. Newer grid without its READY: a snapshot was missed.
        if frame.generation < generation { return [] }
        if frame.generation > generation { return resync(.generationMismatch) }
        guard let tail = Self.newTail(frame, after: offset) else { return resync(.gap) }
        guard !tail.isEmpty else { return [] }
        self.offset = frame.offset
        return [.feed(tail)]
    }

    /// Replay mode has no snapshot to resync from: a gap is dropped silently
    /// (the version fallback is best effort until the versions agree).
    private mutating func replay(_ frame: TerminalFrame) -> [TerminalViewerAction] {
        guard let offset else {
            offset = frame.offset
            return frame.payload.isEmpty ? [] : [.feed(frame.payload)]
        }
        guard let tail = Self.newTail(frame, after: offset), !tail.isEmpty else { return [] }
        self.offset = frame.offset
        return [.feed(tail)]
    }

    /// The part of a bytes frame past `offset`: empty when already applied,
    /// nil when bytes before it were lost.
    private static func newTail(_ frame: TerminalFrame, after offset: UInt64) -> Data? {
        let count = UInt64(frame.payload.count)
        guard frame.offset >= count else { return nil }
        if frame.offset <= offset { return Data() }
        guard frame.offset - count <= offset else { return nil }
        return Data(frame.payload.suffix(Int(frame.offset - offset)))
    }

    private mutating func resync(_ reason: SnapshotRequest.Reason) -> [TerminalViewerAction] {
        mode = .awaitingSnapshot
        return request(reason)
    }

    /// One request in flight: a later trigger before the READY sends nothing.
    private mutating func request(_ reason: SnapshotRequest.Reason) -> [TerminalViewerAction] {
        guard inFlight == nil else { return [] }
        let have = generation.flatMap { g in
            offset.map { SnapshotRequest.Have(generation: g, offset: $0, snapshotVersion: snapshotVersion) }
        }
        let made = SnapshotRequest(terminal: terminal, reason: reason, have: have, requestID: makeRequestID())
        inFlight = made
        return [.requestSnapshot(made)]
    }
}
