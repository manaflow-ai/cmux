public import Foundation

/// What the renderer does with a frame.
public enum TerminalViewerAction: Hashable, Sendable {
    /// Replace the terminal state atomically (READY), at this generation.
    case restore(Data, generation: UInt32)
    /// Prepend history pages to the restored state.
    case prependHistory(Data)
    /// Parse these PTY bytes.
    case feed(Data)
    /// The viewer missed output (a lost frame or a host fault: the host itself
    /// follows every drop and grid change with `snapshot_ready`). Bytes are
    /// dropped until the next READY; the caller reattaches if none arrives
    /// within its timeout. Emitted once per gap.
    case resyncPending
    /// A digest mismatch: ask the host for a snapshot (`snapshot-request`).
    case requestSnapshot
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

    public init(snapshotVersion: UInt16) {
        self.snapshotVersion = snapshotVersion
    }

    /// - Parameter localDigest: SHA-256 of this viewer's own READY encoding,
    ///   or nil when it cannot encode one (then the digest check is skipped).
    public mutating func receive(_ frame: TerminalFrame, localDigest: () -> Data? = { nil }) -> [TerminalViewerAction] {
        if let version = frame.snapshotVersion, version != snapshotVersion {
            // A digest or history of another version is skipped; a READY switches to replay.
            guard frame.kind == .snapshotReady else { return [] }
            mode = .replay
            offset = nil
            return [.versionMismatch(host: version)]
        }
        switch frame.kind {
        case .snapshotReady:
            mode = .live
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
            mode = .awaitingSnapshot
            return [.requestSnapshot]
        }
    }

    private mutating func bytes(_ frame: TerminalFrame) -> [TerminalViewerAction] {
        // Before the first READY, and while a resync is pending, bytes wait for it.
        guard mode == .live, let generation, let offset else { return [] }
        // Older grid: stale. Newer grid without its READY: a snapshot was missed.
        if frame.generation < generation { return [] }
        if frame.generation > generation { return gap() }
        guard let tail = Self.newTail(frame, after: offset) else { return gap() }
        guard !tail.isEmpty else { return [] }
        self.offset = frame.offset
        return [.feed(tail)]
    }

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

    private mutating func gap() -> [TerminalViewerAction] {
        mode = .awaitingSnapshot
        return [.resyncPending]
    }
}
