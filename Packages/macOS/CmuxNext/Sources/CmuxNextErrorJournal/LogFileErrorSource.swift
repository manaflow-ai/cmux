public import Foundation

/// Problems in a growing text log (acpmux `daemon.log`, the Chief host log): lines with a
/// `WARN`, `ERROR` or `FATAL` level word, and Rust panics (the `panicked at` line and the
/// message line after it). Reads only bytes appended since the last harvest; a replaced or
/// truncated file starts over; the first harvest reads at most the last ``firstReadBytes``.
/// Nothing reads at rest, so a file can grow by more than ``maxReadBytes`` between two demands:
/// the read then takes the newest ``maxReadBytes`` and skips the older part.
public struct LogFileErrorSource: ErrorHarvestSource {
    public let id: String
    /// The log file.
    public let url: URL
    /// The ``ErrorEvent/source`` of what it finds.
    public let source: String
    /// The first harvest of a file reads at most this many bytes from its end.
    public let firstReadBytes: Int
    /// One harvest reads at most this many new bytes, the newest ones; older new bytes are skipped.
    public let maxReadBytes: Int

    /// Makes a log source.
    /// - Parameters:
    ///   - id: Cursor key; defaults to `log:<path>`.
    ///   - url: The log file; a missing file yields nothing.
    ///   - source: Event source name, e.g. `acpmux`.
    ///   - firstReadBytes: Tail read on the first harvest.
    ///   - maxReadBytes: Bound of one harvest.
    public init(id: String? = nil, url: URL, source: String, firstReadBytes: Int = 256 << 10,
                maxReadBytes: Int = 4 << 20) {
        self.id = id ?? "log:\(url.path)"
        self.url = url
        self.source = source
        self.firstReadBytes = firstReadBytes
        self.maxReadBytes = maxReadBytes
    }

    public func collect(after cursor: String?) async throws -> ErrorHarvest {
        let files = FileManager()
        guard let attributes = try? files.attributesOfItem(atPath: url.path),
              let size = (attributes[.size] as? NSNumber)?.uint64Value else { return ErrorHarvest(events: [], cursor: cursor) }
        let inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
        // Where to read (a replaced, truncated or first-read file; the bound) is Rust's.
        var request: [String: Any] = ["inode": inode, "size": size, "first_read_bytes": max(0, firstReadBytes),
                                      "max_read_bytes": max(0, maxReadBytes)]
        if let cursor { request["cursor"] = cursor }
        guard let plan = ErrorJournalFFI.decode(Plan.self, "error_journal_log_plan", request) else {
            throw ErrorJournalFFI.Unanswered(operation: "error_journal_log_plan")
        }
        guard plan.read > 0, let handle = try? FileHandle(forReadingFrom: url) else {
            return ErrorHarvest(events: [], cursor: plan.cursor)
        }
        defer { try? handle.close() }
        try handle.seek(toOffset: plan.start)
        let data = try handle.read(upToCount: Int(plan.read)) ?? Data()
        // Only complete lines; a partial last line waits for its newline.
        var chunk: [String: Any] = ["inode": inode, "start": plan.start, "starts_mid_line": plan.startsMidLine,
                                    "complete_bytes": 0, "source": source, "file": url.lastPathComponent,
                                    "now": Date().timeIntervalSince1970]
        if let lastNewline = data.lastIndex(of: UInt8(ascii: "\n")) {
            let complete = data[data.startIndex...lastNewline]
            chunk["complete"] = String(decoding: complete, as: UTF8.self)
            chunk["complete_bytes"] = complete.count
        }
        return try ErrorJournalFFI.harvest("error_journal_log_chunk", chunk)
    }

    private struct Plan: Decodable {
        let start: UInt64
        let read: UInt64
        let startsMidLine: Bool
        let cursor: String

        enum CodingKeys: String, CodingKey {
            case start, read, cursor
            case startsMidLine = "starts_mid_line"
        }
    }
}
