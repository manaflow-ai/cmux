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
    /// The first byte of an `attach-frames-v1` binary frame; never the first byte of a JSON line
    /// (app-daemon-connection-DESIGN.md 3.2).
    static let frameMagic: UInt8 = 0xFF
    /// Bytes in a frame header: magic, kind, u16 stream, u32 payload length, u64 offset (little endian).
    static let frameHeaderBytes = 16

    /// The unfinished line or frame.
    private(set) var pending = Data()
    /// Bytes searched for a newline so far.
    private(set) var scannedBytes = 0
    /// Bytes at the front of `pending` already searched without finding a newline.
    private var searchedPrefix = 0

    /// Appends `bytes` and passes each complete, nonempty line (without its
    /// newline) to `line`, in order. A message that starts with ``frameMagic``
    /// is a binary frame (header and payload, which may hold any byte,
    /// newlines too): it goes whole to `frame`, in the same order.
    mutating func append(_ bytes: some Collection<UInt8>, line: (Data) -> Void, frame: (Data) -> Void = { _ in }) {
        pending.append(contentsOf: bytes)
        let count = pending.count
        var start = 0
        var searchFrom = searchedPrefix
        var searched = 0
        pending.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            while start < count {
                if base.load(fromByteOffset: start, as: UInt8.self) == Self.frameMagic {
                    guard count - start >= Self.frameHeaderBytes else { break }
                    let len = Int(truncatingIfNeeded: UInt32(littleEndian: base.loadUnaligned(fromByteOffset: start + 4, as: UInt32.self)))
                    let end = start + Self.frameHeaderBytes + len
                    guard end <= count else { break }
                    frame(Data(bytes: base + start, count: end - start))
                    start = end
                    searchFrom = start
                    continue
                }
                let from = max(searchFrom, start)
                guard let hit = memchr(base + from, 0x0A, count - from) else {
                    searched += count - from
                    searchFrom = count
                    break
                }
                let found = base.distance(to: UnsafeRawPointer(hit))
                searched += found + 1 - from
                if found > start { line(Data(bytes: base + start, count: found - start)) }
                start = found + 1
                searchFrom = start
            }
        }
        scannedBytes += searched
        if start > 0 { pending.removeSubrange(pending.startIndex..<(pending.startIndex + start)) }
        searchedPrefix = max(0, searchFrom - start)
    }
}
