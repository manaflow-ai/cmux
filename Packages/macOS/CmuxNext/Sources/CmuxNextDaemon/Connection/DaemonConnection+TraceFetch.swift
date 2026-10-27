public import Foundation

/// `trace-fetch` (`trace-fetch-v1`, cmux-tui spec/commands.md; p09-observability-116): one piece of the daemon's own
/// recording ring. The app collects the recording of a daemon on another machine through it, since it cannot read
/// that machine's files; the request names an offset, never a path.
public struct TraceFetchRequest: DaemonRequest {
    public struct Response: Decodable, Sendable, Equatable {
        public var pid: UInt32
        public var offset: UInt64
        /// The length of the copy the offset-0 call took.
        public var totalBytes: UInt64
        /// This piece ends the copy.
        public var done: Bool
        /// The piece in standard base64, at most 1 MiB.
        public var data: String

        enum CodingKeys: String, CodingKey {
            case pid, offset, done, data
            case totalBytes = "total_bytes"
        }
    }

    public static let commandName: DaemonCommandName = "trace-fetch"
    public static var requiredCapability: String? { DaemonCapability.traceFetch.rawValue }
    /// 0 takes a new copy of the recording; a later offset reads that copy.
    public var offset: UInt64

    public init(offset: UInt64) {
        self.offset = offset
    }
}

/// A daemon's recording as its ring file reads, with the clock offset of its machine at the time it was fetched.
public struct DaemonTraceRecording: Sendable, Equatable {
    /// The daemon's process id on its machine.
    public let pid: UInt32
    /// The ring's bytes (`cmux_trace::decode` reads them).
    public let bytes: Data
    /// The machine's trace clock against this Mac's (``ConnectionHeartbeat/clockOffset()``); nil when the heartbeat
    /// has no estimate (it does not run for this connection, or the daemon reads no clock).
    public let clockOffset: DaemonClockOffset?
}

/// Why a trace fetch stopped before its last piece.
public enum DaemonTraceFetchError: Error, Equatable, Sendable {
    /// A piece's `data` was not base64.
    case malformedPiece(offset: UInt64)
    /// A piece started somewhere other than where the last one ended, or its total changed: the daemon's copy was
    /// replaced (a new recording started) while the fetch ran.
    case copyReplaced(offset: UInt64)
    /// The daemon answered a piece with no bytes before the end.
    case emptyPiece(offset: UInt64)
}

extension DaemonTraceRecording {
    /// Reads every piece through `piece` (the `trace-fetch` reply at an offset), from offset 0 until `done`, checking
    /// that each piece starts where the last ended and that the copy's total never changes.
    static func assemble(clockOffset: DaemonClockOffset?,
                         piece fetch: (UInt64) async throws -> TraceFetchRequest.Response) async throws -> DaemonTraceRecording {
        var piece = try await fetch(0)
        let total = piece.totalBytes
        var bytes = Data(capacity: Int(clamping: total))
        try take(piece, total: total, into: &bytes)
        // Each piece before the last adds at least one byte (`take`), so this ends within `total` requests.
        while !piece.done {
            piece = try await fetch(UInt64(truncatingIfNeeded: bytes.count))
            try take(piece, total: total, into: &bytes)
        }
        guard UInt64(truncatingIfNeeded: bytes.count) == total else { throw DaemonTraceFetchError.copyReplaced(offset: piece.offset) }
        return DaemonTraceRecording(pid: piece.pid, bytes: bytes, clockOffset: clockOffset)
    }

    /// Appends `piece` to `bytes` after checking it starts where they end, names the same copy and, unless it is the
    /// last, carries at least one byte.
    private static func take(_ piece: TraceFetchRequest.Response, total: UInt64, into bytes: inout Data) throws {
        guard piece.offset == UInt64(truncatingIfNeeded: bytes.count), piece.totalBytes == total else {
            throw DaemonTraceFetchError.copyReplaced(offset: piece.offset)
        }
        guard let data = Data(base64Encoded: piece.data) else { throw DaemonTraceFetchError.malformedPiece(offset: piece.offset) }
        guard piece.done || !data.isEmpty else { throw DaemonTraceFetchError.emptyPiece(offset: piece.offset) }
        bytes.append(data)
    }
}

extension DaemonConnection {
    /// The daemon's own recording, piece by piece (`trace-fetch`), and its machine's clock offset. Runs on the
    /// caller's executor; each piece is one request with the control deadline, so a slow link holds no other reply
    /// behind a whole ring.
    public nonisolated func fetchTraceRecording() async throws -> DaemonTraceRecording {
        try await DaemonTraceRecording.assemble(clockOffset: heartbeat.clockOffset()) { offset in
            try await request(TraceFetchRequest(offset: offset))
        }
    }

    /// The trace clock offset of this connection's daemon (``ConnectionHeartbeat/clockOffset()``), for a recording's meta.
    public nonisolated func traceClockOffset() -> DaemonClockOffset? {
        heartbeat.clockOffset()
    }
}
