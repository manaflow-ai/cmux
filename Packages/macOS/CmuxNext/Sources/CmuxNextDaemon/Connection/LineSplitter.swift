import Darwin
import Foundation

/// Splits a byte stream into newline-terminated lines (JSON Lines).
///
/// Each byte is searched for a newline once: the buffered rest is one
/// unfinished line, so only the bytes appended last can end it, and each
/// complete line is copied out once. Rescanning the rest on every read was
/// quadratic in the line size, and a 10 MiB terminal replay (one line of
/// about 14 MB) missed the 10 s attach deadline (c997498fd634).
/// `scannedBytes` counts the search work, so tests check the linear bound
/// without timing it.
nonisolated struct LineSplitter {
    /// The unfinished line.
    private(set) var pending = Data()
    /// Bytes searched for a newline so far.
    private(set) var scannedBytes = 0

    /// Appends `bytes` and passes each complete, nonempty line (without its
    /// newline) to `line`, in order.
    mutating func append(_ bytes: some Collection<UInt8>, line: (Data) -> Void) {
        let scanFrom = pending.count
        pending.append(contentsOf: bytes)
        let (lineEnds, searched) = Self.newlineOffsets(in: pending, from: scanFrom)
        scannedBytes += searched
        var start = 0
        for end in lineEnds {
            if end > start {
                let base = pending.startIndex
                line(Data(pending[(base + start)..<(base + end)]))
            }
            start = end + 1
        }
        if start > 0 { pending.removeSubrange(pending.startIndex..<(pending.startIndex + start)) }
    }

    /// Offsets (from `data.startIndex`) of every newline at or after
    /// `offset`, and the number of bytes searched for them.
    static func newlineOffsets(in data: Data, from offset: Int) -> (offsets: [Int], searched: Int) {
        data.withUnsafeBytes { raw -> ([Int], Int) in
            guard let base = raw.baseAddress, offset < raw.count else { return ([], 0) }
            var offsets: [Int] = []
            var position = offset
            while position < raw.count, let hit = memchr(base + position, 0x0A, raw.count - position) {
                let found = base.distance(to: UnsafeRawPointer(hit))
                offsets.append(found)
                position = found + 1
            }
            // memchr reads up to the newline it finds, or to the end.
            return (offsets, raw.count - offset)
        }
    }
}
