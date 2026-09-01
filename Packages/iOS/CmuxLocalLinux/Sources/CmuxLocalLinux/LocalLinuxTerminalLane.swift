#if canImport(IshKernel)
public import CmuxMobileRPC
public import Foundation

/// `MobileTerminalLaneConnection` over one local iSH session, so a local
/// Linux terminal plugs into the same `MobileTerminalLaneCoordinator` path a
/// paired Mac uses.
///
/// Sequencing contract (mirrors the Mac's envelope semantics, which the
/// coordinator validates): the FIRST frame is always `.replay` carrying the
/// retained scrollback ring from `cursor` (empty on a fresh session), and
/// every subsequent chunk carries monotonically increasing byte sequences.
/// The lane retains a bounded ring so a remount replays recent scrollback
/// instead of a blank grid.
public actor LocalLinuxTerminalLane: MobileTerminalLaneConnection {
    /// Retained replay budget per terminal; beyond this the base advances.
    public static let retainedByteLimit = 512 * 1_024

    private let session: LocalLinuxSession
    private let ring: LocalLinuxScrollbackRing
    private var iterator: AsyncStream<Data>.Iterator?
    private var sentReplay = false
    private var requestedCursor: UInt64?
    private var closed = false

    /// - Parameters:
    ///   - session: The running local session.
    ///   - ring: The per-terminal retained output ring (owned by the local
    ///     workspace model so it outlives individual lane attachments).
    ///   - cursor: The coordinator's resume cursor, or nil for a cold attach.
    public init(session: LocalLinuxSession, ring: LocalLinuxScrollbackRing, cursor: UInt64?) {
        self.session = session
        self.ring = ring
        self.requestedCursor = cursor
    }

    public func receiveOutput() async throws -> MobileTerminalLaneOutputFrame? {
        guard !closed else { return nil }
        if !sentReplay {
            sentReplay = true
            iterator = session.output.makeAsyncIterator()
            let snapshot = await ring.snapshot(from: requestedCursor)
            return MobileTerminalLaneOutputFrame(
                kind: .replay,
                retainedBaseSequence: snapshot.baseSequence,
                sequence: snapshot.baseSequence,
                currentSequence: snapshot.currentSequence,
                bytes: snapshot.bytes
            )
        }
        guard var iterator else { return nil }
        guard let chunk = await iterator.next() else {
            self.iterator = nil
            return nil
        }
        self.iterator = iterator
        let stamped = await ring.append(chunk)
        return MobileTerminalLaneOutputFrame(
            kind: .chunk,
            retainedBaseSequence: stamped.baseSequence,
            sequence: stamped.startSequence,
            currentSequence: stamped.currentSequence,
            bytes: chunk
        )
    }

    public func sendInput(_ input: String) async throws {
        guard !closed else { throw LocalLinuxLaneError.closed }
        session.send(Data(input.utf8))
    }

    public func close() async {
        closed = true
        iterator = nil
    }
}

public enum LocalLinuxLaneError: Error, Equatable, Sendable {
    case closed
}

/// Bounded retained-output ring for one local terminal: the local analogue of
/// the Mac's per-surface byte tee, so reattach gets scrollback replay.
public actor LocalLinuxScrollbackRing {
    public struct Snapshot: Sendable {
        public let baseSequence: UInt64
        public let currentSequence: UInt64
        public let bytes: Data
    }

    public struct Stamp: Sendable {
        public let baseSequence: UInt64
        public let startSequence: UInt64
        public let currentSequence: UInt64
    }

    private var buffer = Data()
    private var baseSequence: UInt64 = 0
    private let limit: Int

    public init(limit: Int = LocalLinuxTerminalLane.retainedByteLimit) {
        self.limit = limit
    }

    public var currentSequence: UInt64 { baseSequence + UInt64(buffer.count) }

    public func append(_ chunk: Data) -> Stamp {
        let start = currentSequence
        buffer.append(chunk)
        if buffer.count > limit {
            let drop = buffer.count - limit
            buffer.removeFirst(drop)
            baseSequence += UInt64(drop)
        }
        return Stamp(
            baseSequence: baseSequence,
            startSequence: start,
            currentSequence: currentSequence
        )
    }

    /// Retained bytes from `cursor` (clamped into the retained window).
    public func snapshot(from cursor: UInt64?) -> Snapshot {
        let current = currentSequence
        let from = min(max(cursor ?? baseSequence, baseSequence), current)
        let offset = Int(from - baseSequence)
        return Snapshot(
            baseSequence: from,
            currentSequence: current,
            bytes: buffer.suffix(buffer.count - offset)
        )
    }
}
#endif
