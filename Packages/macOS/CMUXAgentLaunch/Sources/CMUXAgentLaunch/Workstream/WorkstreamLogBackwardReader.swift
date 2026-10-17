import Foundation

/// Reads the rows of the append-only workstream log newest-first, walking
/// backward from a byte offset in fixed-size chunks.
///
/// Memory stays bounded by one chunk plus the row being assembled. A row
/// longer than `maximumRowBytes` cannot be a valid item, so it is dropped as
/// it is read; otherwise a corrupt region with no newline would pull the
/// whole log into memory. Chunks are read with `pread` into Swift-owned
/// buffers: `FileHandle.read` returns autoreleased `NSData`, which a loop on
/// a concurrency thread keeps alive until the whole scan ends.
struct WorkstreamLogBackwardReader {
    struct Row: Equatable {
        let bytes: Data
        /// Byte offset of the row's first byte. It stays valid while rows are
        /// appended, so it can be handed back as a paging cursor.
        let startOffset: UInt64
    }

    /// Far above any real row (they are a few KB), far below a memory spike.
    static let defaultMaximumRowBytes = 16 * 1024 * 1024

    private let handle: FileHandle
    private let chunkSize: Int
    private let maximumRowBytes: Int
    /// Read but not yet returned. It ends where the last returned row began,
    /// so its final line is the next row.
    private var pending = Data()
    /// File offset of `pending`'s first byte. Everything before it is unread.
    private var pendingStart: UInt64

    init(
        handle: FileHandle,
        endOffset: UInt64,
        chunkSize: Int = 64 * 1024,
        maximumRowBytes: Int = Self.defaultMaximumRowBytes
    ) {
        self.handle = handle
        self.pendingStart = endOffset
        self.chunkSize = max(1, chunkSize)
        self.maximumRowBytes = max(1, maximumRowBytes)
    }

    /// Returns the next row toward the start of the file, or nil once the
    /// start is reached. Empty lines and rows over `maximumRowBytes` are
    /// skipped.
    mutating func next() throws -> Row? {
        while true {
            if let newline = Self.lastNewline(in: pending) {
                let rowStart = newline + 1
                let bytes = pending[rowStart...]
                let startOffset = pendingStart + UInt64(rowStart - pending.startIndex)
                pending = pending[..<newline]
                if bytes.isEmpty || bytes.count > maximumRowBytes { continue }
                return Row(bytes: Data(bytes), startOffset: startOffset)
            }
            if pendingStart == 0 {
                let bytes = pending
                pending = Data()
                guard !bytes.isEmpty, bytes.count <= maximumRowBytes else { return nil }
                return Row(bytes: Data(bytes), startOffset: 0)
            }
            try readThroughRowStart()
        }
    }

    /// Reads backward until `pending` contains the newline that starts its
    /// final row, or the start of the file. Chunks of a long row are joined
    /// once instead of on every read. A row that outgrows `maximumRowBytes` is
    /// discarded while reading continues to the newline before it.
    private mutating func readThroughRowStart() throws {
        var chunks: [Data] = []
        var byteCount = pending.count
        var isDroppingRow = false
        while pendingStart > 0 {
            let readSize = Int(min(UInt64(chunkSize), pendingStart))
            let readStart = pendingStart - UInt64(readSize)
            guard let chunk = try readChunk(at: readStart, count: readSize) else {
                // The log shrank (cleared or rotated). Stop rather than join
                // bytes from two different files into one row.
                pending = Data()
                pendingStart = 0
                return
            }
            pendingStart = readStart
            if isDroppingRow {
                guard Self.containsNewline(chunk),
                      let newline = Self.lastNewline(in: chunk) else { continue }
                pending = chunk[..<newline]
                return
            }
            chunks.append(chunk)
            byteCount += chunk.count
            if Self.containsNewline(chunk) { break }
            if byteCount > maximumRowBytes {
                chunks.removeAll()
                pending = Data()
                isDroppingRow = true
            }
        }
        if isDroppingRow {
            // The oversized row was the first row of the file.
            pending = Data()
            return
        }
        var joined = Data(capacity: byteCount)
        for chunk in chunks.reversed() {
            joined.append(chunk)
        }
        joined.append(pending)
        pending = joined
    }

    /// Reads exactly `count` bytes at `offset`, or nil when the file ends first.
    private func readChunk(at offset: UInt64, count: Int) throws -> Data? {
        var chunk = Data(count: count)
        var filled = 0
        while filled < count {
            let result = chunk.withUnsafeMutableBytes { raw in
                pread(handle.fileDescriptor, raw.baseAddress! + filled, count - filled, off_t(offset) + off_t(filled))
            }
            if result > 0 {
                filled += result
            } else if result == 0 {
                return nil
            } else if errno != EINTR {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        }
        return chunk
    }

    private static func containsNewline(_ data: Data) -> Bool {
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress, !raw.isEmpty else { return false }
            return memchr(base, 0x0A, raw.count) != nil
        }
    }

    /// Index of the final newline. Scans from the end, so finding the next
    /// row costs that row's length rather than everything still pending.
    private static func lastNewline(in data: Data) -> Data.Index? {
        let offset: Int? = data.withUnsafeBytes { raw in
            var index = raw.count
            while index > 0 {
                index -= 1
                if raw[index] == 0x0A { return index }
            }
            return nil
        }
        return offset.map { data.startIndex + $0 }
    }
}
