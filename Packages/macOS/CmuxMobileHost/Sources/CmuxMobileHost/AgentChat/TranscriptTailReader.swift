import Foundation

/// Limits for one bounded read of a transcript's tail.
struct TranscriptTailLimits: Sendable, Equatable {
    /// The most recent complete lines a window may hold.
    let maxLines: Int
    /// Total bytes of the records a window may decode.
    let maxBytes: Int
    /// Bytes above which one record is skipped instead of decoded. Must not
    /// exceed `maxBytes`, so a kept trailing fragment stays within the budget.
    let maxRecordBytes: Int
}

/// The located tail of a transcript. Holds offsets only, so its size follows
/// `maxLines` and never the size of the file.
struct TranscriptTailWindow: Sendable, Equatable {
    /// Identity of the file that was scanned.
    let inode: UInt64
    /// Bytes scanned, which is where an append reader continues.
    let byteCount: UInt64
    /// Complete (newline-terminated) lines in the file.
    let completeLineCount: Int
    /// Absolute line index of the first line in `lineRanges`.
    let firstLine: Int
    /// Byte ranges of the window's lines, oldest first, without their newlines.
    let lineRanges: [Range<UInt64>]
    /// Absolute line indexes in the window that exceed `maxRecordBytes`.
    let oversizedLines: [Int]
    /// The bytes after the last newline.
    let trailingFragment: Range<UInt64>
}

/// Reads a transcript's tail without mapping or buffering the whole file.
///
/// `seq` is an absolute line index, so locating the tail still counts every
/// newline once. The count walks a fixed buffer and keeps a fixed ring of
/// offsets, and both it and record decoding stop when the task is cancelled.
final class TranscriptTailReader {
    private static let scanChunkBytes = 64 * 1024

    private let descriptor: Int32

    /// Opens a transcript for reading, or answers `nil` when it can't be opened.
    init?(path: String) {
        let descriptor = open(path, O_RDONLY | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        self.descriptor = descriptor
        // The scan touches every page once; keep it out of the file cache.
        _ = fcntl(descriptor, F_NOCACHE, 1)
    }

    deinit {
        close(descriptor)
    }

    /// Locates the newest lines that fit `limits`.
    ///
    /// A line over `maxRecordBytes` stays in the window, costs no budget and is
    /// listed in `oversizedLines`, so one huge record can't hide its neighbors.
    /// The trailing fragment, which a caller may decode as a last record, is
    /// charged first unless it exceeds `maxRecordBytes`. The window ends where
    /// the next older line would exceed `maxBytes`, and holds at most
    /// `maxLines` lines.
    ///
    /// - Throws: `CancellationError` when the task is cancelled, or the read
    ///   error from the file.
    func scan(limits: TranscriptTailLimits) throws -> TranscriptTailWindow {
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { throw Self.lastError() }

        let capacity = max(1, limits.maxLines)
        var lineStarts = [UInt64](repeating: 0, count: capacity)
        var completeLines = 0
        var currentStart: UInt64 = 0
        var offset: UInt64 = 0

        let buffer = UnsafeMutableRawBufferPointer.allocate(
            byteCount: Self.scanChunkBytes,
            alignment: 1
        )
        defer { buffer.deallocate() }
        let base = UnsafeRawPointer(buffer.baseAddress!)
        while true {
            try Task.checkCancellation()
            let count = try read(into: buffer, at: offset)
            if count == 0 { break }
            var cursor = 0
            while cursor < count, let hit = memchr(base + cursor, 0x0A, count - cursor) {
                let index = base.distance(to: UnsafeRawPointer(hit))
                lineStarts[completeLines % capacity] = currentStart
                completeLines += 1
                currentStart = offset + UInt64(index) + 1
                cursor = index + 1
            }
            offset += UInt64(count)
        }

        // Newest to oldest, stopping at the first line the budget can't hold.
        let oldestRetained = completeLines - min(completeLines, capacity)
        var firstLine = completeLines
        let fragmentLength = Int(clamping: offset - currentStart)
        var usedBytes = fragmentLength > limits.maxRecordBytes ? 0 : fragmentLength
        var oversizedNewestFirst: [Int] = []
        var line = completeLines - 1
        while line >= oldestRetained, completeLines - line <= limits.maxLines {
            let start = lineStarts[line % capacity]
            let end = line + 1 < completeLines ? lineStarts[(line + 1) % capacity] : currentStart
            let length = Int(clamping: end - 1 - start)
            if length > limits.maxRecordBytes {
                oversizedNewestFirst.append(line)
            } else {
                guard usedBytes + length <= limits.maxBytes else { break }
                usedBytes += length
            }
            firstLine = line
            line -= 1
        }

        var ranges: [Range<UInt64>] = []
        ranges.reserveCapacity(completeLines - firstLine)
        for line in firstLine..<completeLines {
            let start = lineStarts[line % capacity]
            let end = line + 1 < completeLines ? lineStarts[(line + 1) % capacity] : currentStart
            ranges.append(start..<(end - 1))
        }
        return TranscriptTailWindow(
            inode: UInt64(info.st_ino),
            byteCount: offset,
            completeLineCount: completeLines,
            firstLine: firstLine,
            lineRanges: ranges,
            oversizedLines: oversizedNewestFirst.reversed(),
            trailingFragment: currentStart..<offset
        )
    }

    /// The window's lines as a lazy sequence that decodes one record at a time.
    ///
    /// An oversized line yields an empty string, which parsers drop while still
    /// consuming its `seq`. Iteration ends early when the task is cancelled, so
    /// callers must check for cancellation before trusting the result.
    func lines(
        in ranges: [Range<UInt64>],
        maxRecordBytes: Int
    ) -> TranscriptTailLineSequence {
        TranscriptTailLineSequence(reader: self, ranges: ranges, maxRecordBytes: maxRecordBytes)
    }

    /// Reads a byte range, answering what could be read. A short result is a
    /// file that shrank underneath the scan; parsers drop the partial record.
    func data(in range: Range<UInt64>) -> Data {
        let wanted = Int(clamping: range.upperBound - range.lowerBound)
        guard wanted > 0 else { return Data() }
        var data = Data(count: wanted)
        let received = data.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) -> Int in
            var total = 0
            while total < wanted {
                let slice = UnsafeMutableRawBufferPointer(rebasing: raw[total...])
                guard let count = try? read(into: slice, at: range.lowerBound + UInt64(total)),
                      count > 0 else {
                    break
                }
                total += count
            }
            return total
        }
        if received < wanted {
            data.removeSubrange(received..<wanted)
        }
        return data
    }

    private func read(into buffer: UnsafeMutableRawBufferPointer, at offset: UInt64) throws -> Int {
        while true {
            let count = pread(descriptor, buffer.baseAddress, buffer.count, off_t(offset))
            if count >= 0 { return count }
            if errno != EINTR { throw Self.lastError() }
        }
    }

    private static func lastError() -> any Error {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}

/// The lazily decoded lines of a ``TranscriptTailWindow``.
struct TranscriptTailLineSequence: Sequence, IteratorProtocol {
    fileprivate let reader: TranscriptTailReader
    fileprivate let ranges: [Range<UInt64>]
    fileprivate let maxRecordBytes: Int
    private var index = 0

    fileprivate init(reader: TranscriptTailReader, ranges: [Range<UInt64>], maxRecordBytes: Int) {
        self.reader = reader
        self.ranges = ranges
        self.maxRecordBytes = maxRecordBytes
    }

    mutating func next() -> String? {
        guard index < ranges.count, !Task.isCancelled else { return nil }
        let range = ranges[index]
        index += 1
        guard range.upperBound - range.lowerBound <= UInt64(maxRecordBytes) else { return "" }
        return String(decoding: reader.data(in: range), as: UTF8.self)
    }
}

/// Splits appended transcript bytes into lines, holding at most one record.
///
/// A record that outgrows `maxRecordBytes` stops being buffered: the rest of it
/// is discarded as it arrives, and it comes out as one ``Line/oversized`` line
/// so it still consumes its `seq`.
struct TranscriptLineAssembler: Sendable {
    /// One complete transcript line.
    enum Line: Sendable, Equatable {
        /// A record within the limit.
        case record(String)
        /// A record over the limit, whose bytes were not kept.
        case oversized
    }

    private let maxRecordBytes: Int
    private var fragment = Data()
    private var isDiscarding = false

    /// Creates an assembler with an empty fragment.
    init(maxRecordBytes: Int) {
        self.maxRecordBytes = maxRecordBytes
    }

    /// Creates an assembler continuing a partial record of a known length,
    /// whose bytes are supplied only when it is within the limit.
    init(maxRecordBytes: Int, fragmentByteCount: UInt64, fragment: () -> Data) {
        self.maxRecordBytes = maxRecordBytes
        if fragmentByteCount > UInt64(maxRecordBytes) {
            isDiscarding = true
        } else {
            self.fragment = fragment()
        }
    }

    /// Consumes a chunk of appended bytes.
    ///
    /// - Returns: The lines the chunk completed, in file order.
    mutating func consume(_ chunk: Data) -> [Line] {
        var lines: [Line] = []
        chunk.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            var cursor = 0
            while cursor < raw.count, let hit = memchr(base + cursor, 0x0A, raw.count - cursor) {
                let index = base.distance(to: UnsafeRawPointer(hit))
                lines.append(completeLine(UnsafeRawBufferPointer(rebasing: raw[cursor..<index])))
                cursor = index + 1
            }
            accumulate(UnsafeRawBufferPointer(rebasing: raw[cursor...]))
        }
        return lines
    }

    private mutating func completeLine(_ tail: UnsafeRawBufferPointer) -> Line {
        accumulate(tail)
        defer {
            fragment = Data()
            isDiscarding = false
        }
        return isDiscarding ? .oversized : .record(String(decoding: fragment, as: UTF8.self))
    }

    private mutating func accumulate(_ bytes: UnsafeRawBufferPointer) {
        guard !isDiscarding else { return }
        if fragment.count + bytes.count > maxRecordBytes {
            fragment = Data()
            isDiscarding = true
        } else {
            fragment.append(contentsOf: bytes)
        }
    }
}
