public import Foundation
import CmuxNextCompat

/// Problems in a growing text log (acpmux `daemon.log`, the Chief host log): lines with a
/// `WARN`, `ERROR` or `FATAL` level word, and Rust panics (the `panicked at` line and the
/// message line after it). Reads only bytes appended since the last harvest; a replaced or
/// truncated file starts over; the first harvest reads at most the last ``firstReadBytes``.
public struct LogFileErrorSource: ErrorHarvestSource {
    public let id: String
    /// The log file.
    public let url: URL
    /// The ``ErrorEvent/source`` of what it finds.
    public let source: String
    /// The first harvest of a file reads at most this many bytes from its end.
    public let firstReadBytes: Int
    /// One harvest reads at most this many new bytes; the rest waits for the next one
    /// (``ErrorHarvest/more``).
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
        try harvest(after: cursor)
    }

    /// ``collect(after:)`` as a plain call, for the synchronous fuzz entry (p10-stability-029).
    func harvest(after cursor: String?) throws -> ErrorHarvest {
        guard let attributes: [FileAttributeKey: Any] = try? FileManager.checked.attributesOfItem(atPath: url.path),
              let size = (attributes[.size] as? NSNumber)?.intValue else { return ErrorHarvest(events: [], cursor: cursor) }
        let inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
        var start: Int
        if let cursor, let saved = Self.parse(cursor), saved.inode == inode, saved.offset <= size {
            start = saved.offset
        } else if cursor == nil {
            start = max(0, size - firstReadBytes)
        } else {
            start = 0
        }
        guard start < size, let offset = UInt64(exactly: start), let handle = try? FileHandle.blockingForReading(from: url) else {
            return ErrorHarvest(events: [], cursor: "\(inode):\(size)")
        }
        defer { try? handle.close() }
        try handle.seek(toOffset: offset)
        let data = try handle.blockingRead(upToCount: min(size - start, maxReadBytes)) ?? Data()
        // Only complete lines; a partial last line waits for its newline.
        let partial = data.reversed().prefix { $0 != UInt8(ascii: "\n") }.count
        guard partial < data.count else {
            return ErrorHarvest(events: [], cursor: "\(inode):\(start)")
        }
        let complete = data.dropLast(partial)
        var text = String(decoding: complete, as: UTF8.self)
        let afterFirstBreak = text.drop { $0 != "\n" }
        if cursor == nil, start > 0, !afterFirstBreak.isEmpty {
            text = String(afterFirstBreak.dropFirst()) // the tail began mid-line
        }
        let events = LogLineParser(source: source, file: url.lastPathComponent).events(in: text)
        return ErrorHarvest(events: events, cursor: "\(inode):\(start + complete.count)", more: size - start > maxReadBytes)
    }

    private static func parse(_ cursor: String) -> (inode: UInt64, offset: Int)? {
        let parts = cursor.split(separator: ":")
        // A negative offset (a damaged cursors.json) would trap in `UInt64(_:)` at the seek.
        guard parts.count == 2, let inode = UInt64(parts[0]), let offset = Int(parts[1]), offset >= 0 else { return nil }
        return (inode, offset)
    }
}
