public import Foundation

/// `trace-fetch` (`trace-fetch-v1`, cmux-tui spec/commands.md; p09-observability-116): one piece of the daemon's own
/// recording ring. The app collects the recording of a daemon on another machine through it, since it cannot read
/// that machine's files; the request names an offset, never a path.
public struct TraceFetchRequest: DaemonRequest {
    public struct Response: Decodable, Sendable, Equatable {
        public var pid: UInt32
        /// The copy the offset-0 call took; every later piece of the fetch names it.
        public var fetchID: UInt64
        public var offset: UInt64
        /// The length of the copy the offset-0 call took.
        public var totalBytes: UInt64
        /// This piece ends the copy.
        public var done: Bool
        /// The piece in standard base64, at most 1 MiB.
        public var data: String

        enum CodingKeys: String, CodingKey {
            case pid, offset, done, data
            case fetchID = "fetch_id"
            case totalBytes = "total_bytes"
        }
    }

    public static let commandName: DaemonCommandName = "trace-fetch"
    public static var requiredCapability: String? { DaemonCapability.traceFetch.rawValue }
    /// 0 takes a new copy of the recording; a later offset reads that copy.
    public var offset: UInt64
    /// Past offset 0, the offset-0 reply's ``Response/fetchID``: the daemon refuses a piece of a copy another
    /// fetch replaced. Nil at offset 0.
    public var fetchID: UInt64?

    public init(offset: UInt64, fetchID: UInt64? = nil) {
        self.offset = offset
        self.fetchID = fetchID
    }

    enum CodingKeys: String, CodingKey {
        case offset
        case fetchID = "fetch_id"
    }
}

/// A daemon's recording as its ring file reads, with the clock offset of its machine at the time it was fetched.
public struct DaemonTraceRecording: Sendable, Equatable {
    /// The most bytes a fetched recording may have: the ring bytes one `trace-start` maps across a daemon and all
    /// its children (cmux-tui-core server/trace_control.rs `TOTAL_CAP_BYTES`), so no single ring is larger. The
    /// daemon's own ring is 32 MiB of chunks and its tables.
    public static let maxBytes: UInt64 = 128 << 20

    /// The daemon's process id on its machine.
    public let pid: UInt32
    /// The ring's bytes (`cmux_trace::decode` reads them).
    public let bytes: Data
    /// The machine's trace clock against this Mac's (``ConnectionHeartbeat/clockOffset()``); nil when the heartbeat
    /// has no estimate yet (no answer since the connection or this Mac's last sleep, or the daemon reads no clock).
    public let clockOffset: DaemonClockOffset?
}

/// Why a trace fetch stopped before its last piece.
public enum DaemonTraceFetchError: Error, Equatable, Sendable {
    /// A piece's `data` was not base64.
    case malformedPiece(offset: UInt64)
    /// A piece started somewhere other than where the last one ended, or named another fetch's copy or total: the
    /// daemon's copy was replaced (a new recording started, or another client began a fetch) while this one ran.
    case copyReplaced(offset: UInt64)
    /// The daemon's copy is longer than any recording ring (``DaemonTraceRecording/maxBytes``), or its pieces run
    /// past the length it gave: no memory is reserved for a reply from another machine past that bound.
    case tooLarge(totalBytes: UInt64)
    /// The daemon answered a piece with no bytes before the end.
    case emptyPiece(offset: UInt64)
}

extension DaemonTraceRecording {
    /// Reads every piece through `piece` (the `trace-fetch` request at an offset with the fetch's id, nil at offset 0),
    /// from offset 0 until `done`, checking that each piece starts where the last ended, names the same copy and
    /// total, and stays within that total and ``maxBytes``.
    static func assemble(clockOffset: DaemonClockOffset?,
                         piece fetch: (TraceFetchRequest) async throws -> TraceFetchRequest.Response) async throws -> DaemonTraceRecording {
        var piece = try await fetch(TraceFetchRequest(offset: 0))
        let first = piece
        guard first.totalBytes <= maxBytes else { throw DaemonTraceFetchError.tooLarge(totalBytes: first.totalBytes) }
        var bytes = Data(capacity: Int(truncatingIfNeeded: first.totalBytes))
        try take(piece, of: first, into: &bytes)
        // Each piece before the last adds at least one byte (`take`), so this ends within `total` requests.
        while !piece.done {
            piece = try await fetch(TraceFetchRequest(offset: UInt64(truncatingIfNeeded: bytes.count), fetchID: first.fetchID))
            try take(piece, of: first, into: &bytes)
        }
        guard UInt64(truncatingIfNeeded: bytes.count) == first.totalBytes else {
            throw DaemonTraceFetchError.copyReplaced(offset: piece.offset)
        }
        return DaemonTraceRecording(pid: piece.pid, bytes: bytes, clockOffset: clockOffset)
    }

    /// Appends `piece` to `bytes` after checking it starts where they end, names `first`'s copy and total, stays
    /// within that total and, unless it is the last, carries at least one byte.
    private static func take(_ piece: TraceFetchRequest.Response, of first: TraceFetchRequest.Response, into bytes: inout Data) throws {
        guard piece.offset == UInt64(truncatingIfNeeded: bytes.count), piece.fetchID == first.fetchID,
              piece.totalBytes == first.totalBytes else {
            throw DaemonTraceFetchError.copyReplaced(offset: piece.offset)
        }
        guard let data = Data(base64Encoded: piece.data) else { throw DaemonTraceFetchError.malformedPiece(offset: piece.offset) }
        guard UInt64(truncatingIfNeeded: data.count) <= first.totalBytes - piece.offset else {
            throw DaemonTraceFetchError.tooLarge(totalBytes: first.totalBytes)
        }
        guard piece.done || !data.isEmpty else { throw DaemonTraceFetchError.emptyPiece(offset: piece.offset) }
        bytes.append(data)
    }
}

extension DaemonConnection {
    /// The daemon's own recording, piece by piece (`trace-fetch`), and its machine's clock offset. Runs on the
    /// caller's executor; each piece is one request with the control deadline, so a slow link holds no other reply
    /// behind a whole ring.
    public nonisolated func fetchTraceRecording() async throws -> DaemonTraceRecording {
        try await DaemonTraceRecording.assemble(clockOffset: heartbeat.clockOffset()) { piece in
            try await request(piece)
        }
    }

    /// The trace clock offset of this connection's daemon (``ConnectionHeartbeat/clockOffset()``), for a recording's meta.
    public nonisolated func traceClockOffset() -> DaemonClockOffset? {
        heartbeat.clockOffset()
    }
}
