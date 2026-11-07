import CCmuxRdFFI
public import Foundation

/// The stdout lines of `cmux rd serve|connect`, read by the shared Rust reader (crate cmux-rd-ffi,
/// `CmuxRdLineReader`): the host prints `cmux_rd_proto::app_line::AppLine` and the same type reads
/// it back here, so the app keeps no copy of the line format. Bytes go in; typed lines come out.
/// No I/O, threads or timers inside. Not thread-safe: one reader per process stream, used from one
/// queue at a time (the pipe's), so the type is not `Sendable`.
public nonisolated final class RemoteRdLineReader {
    /// The link's path in use.
    public struct Path: Sendable, Equatable {
        /// The path kind's wire name (`direct_lan`, `direct_wan`, ...).
        public var kind: String?
        /// The round trip in milliseconds.
        public var rttMs: Double?
    }

    /// One line; a field the line does not hold is nil.
    public struct Line: Sendable, Equatable {
        public var key: String?
        public var candidate: String?
        public var candidatesDone: Bool?
        public var connected: Bool?
        public var listening: Bool?
        public var ended: String?
        public var path: Path?
        /// Each display's size in pixels, `[width, height]`.
        public var displays: [[UInt32]]?
        public var current: Int?
        public var error: String?
    }

    private let handle: OpaquePointer

    /// Nil only when the core cannot allocate a reader.
    public init?() {
        guard let handle = cmux_rd_line_reader_new() else { return nil }
        self.handle = handle
    }

    deinit {
        cmux_rd_line_reader_free(handle)
    }

    /// Adds stdout bytes and returns every line they complete, in order. A line that is not an
    /// app line (a newer cmux's, or not JSON) is left out.
    public func push(_ bytes: Data) -> [Line] {
        let ready = bytes.withUnsafeBytes { raw in
            cmux_rd_line_reader_push(handle, raw.baseAddress?.assumingMemoryBound(to: UInt8.self), raw.count)
        }
        guard ready > 0 else { return [] }
        var lines: [Line] = []
        lines.reserveCapacity(Int(ready))
        var raw = CmuxRdLine()
        while cmux_rd_line_reader_next(handle, &raw) == 1 {
            lines.append(Self.line(raw))
        }
        return lines
    }

    /// Copies a reader line out (its pointers stay valid only until the next call on the reader).
    private static func line(_ raw: CmuxRdLine) -> Line {
        func has(_ bit: some BinaryInteger) -> Bool { raw.fields & UInt32(bit) != 0 }
        func text(_ pointer: UnsafePointer<UInt8>?, _ count: Int, _ bit: some BinaryInteger) -> String? {
            guard has(bit) else { return nil }
            guard let pointer, count > 0 else { return "" }
            return String(decoding: UnsafeBufferPointer(start: pointer, count: count), as: UTF8.self)
        }
        var line = Line()
        line.key = text(raw.key, raw.key_len, CMUX_RD_LINE_KEY)
        line.candidate = text(raw.candidate, raw.candidate_len, CMUX_RD_LINE_CANDIDATE)
        line.ended = text(raw.ended, raw.ended_len, CMUX_RD_LINE_ENDED)
        line.error = text(raw.error, raw.error_len, CMUX_RD_LINE_ERROR)
        if has(CMUX_RD_LINE_CANDIDATES_DONE) { line.candidatesDone = true }
        if has(CMUX_RD_LINE_CONNECTED) { line.connected = true }
        if has(CMUX_RD_LINE_LISTENING) { line.listening = true }
        if has(CMUX_RD_LINE_PATH) {
            line.path = Path(kind: text(raw.path_kind, raw.path_kind_len, CMUX_RD_LINE_PATH_KIND),
                             rttMs: has(CMUX_RD_LINE_PATH_RTT) ? raw.path_rtt_ms : nil)
        }
        if has(CMUX_RD_LINE_DISPLAYS) {
            let flat = raw.displays.map { Array(UnsafeBufferPointer(start: $0, count: raw.display_count * 2)) } ?? []
            line.displays = stride(from: 0, to: flat.count, by: 2).map { [flat[$0], flat[$0 + 1]] }
        }
        if has(CMUX_RD_LINE_CURRENT) { line.current = Int(clamping: raw.current) }
        return line
    }
}
