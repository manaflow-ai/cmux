#if canImport(Compression)
import Compression
#else
import CZlib
#endif
import Foundation

/// Inflates a compressed `snapshot {phase: "history"}` chunk
/// (`terminal-snapshot-history-v1`). The host compresses each chunk on its
/// own, so each inflates alone. Runs on the attach reader thread, never the
/// main thread.
enum TerminalSnapshotInflate {
    /// `compression` values this view inflates. `deflate` is raw DEFLATE
    /// (RFC 1951, no zlib or gzip framing): what COMPRESSION_ZLIB reads on
    /// macOS and zlib reads with a negative window size on Linux.
    static let supported: Set<String> = ["deflate"]
    /// Largest uncompressed chunk accepted (the host sends at most 1 MiB).
    static let maxRawBytes = 8 << 20

    /// The chunk's bytes, or nil for an unknown codec, a size over the cap,
    /// or data that does not inflate to exactly `rawBytes`.
    static func inflate(_ data: Data, compression: String?, rawBytes: Int?) -> Data? {
        guard let compression else { return data }
        guard supported.contains(compression), let rawBytes, rawBytes >= 0, rawBytes <= maxRawBytes else { return nil }
        guard rawBytes > 0 else { return data.isEmpty ? Data() : nil }
        guard !data.isEmpty else { return nil }
        // One spare byte: an input that inflates past rawBytes fills it.
        var out = Data(count: rawBytes + 1)
        // SAFETY: `dst` and `src` are the storage of `out` (rawBytes + 1 bytes) and `data` (data.count bytes),
        // valid only inside these closures, which never let a pointer out; both are plain bytes, so binding them to
        // UInt8 changes no other typed view. `rawInflate` writes at most the rawBytes + 1 it is given and reads at
        // most data.count.
        let written = unsafe out.withUnsafeMutableBytes { dst -> Int in
            unsafe data.withUnsafeBytes { src -> Int in
                guard let target = unsafe dst.bindMemory(to: UInt8.self).baseAddress,
                      let source = unsafe src.bindMemory(to: UInt8.self).baseAddress else { return -1 }
                return unsafe rawInflate(into: target, capacity: rawBytes + 1, from: source, count: data.count)
            }
        }
        guard written == rawBytes else { return nil }
        out.count = rawBytes  // drops the spare byte
        return out
    }

    #if canImport(Compression)
    /// The bytes raw DEFLATE `source` inflates to in `target`, at most `capacity`.
    private static func rawInflate(into target: UnsafeMutablePointer<UInt8>, capacity: Int,
                                   from source: UnsafePointer<UInt8>, count: Int) -> Int {
        // SAFETY: the caller's buffers hold `capacity` and `count` bytes for the call; a nil scratch buffer makes
        // compression_decode_buffer allocate its own.
        unsafe compression_decode_buffer(target, capacity, source, count, nil, COMPRESSION_ZLIB)
    }
    #else
    /// The bytes raw DEFLATE `source` inflates to in `target`, or -1 when the stream is bad, does not end
    /// within `count` bytes, or needs more than `capacity`. zlib's raw mode is a negative window size
    /// (`inflateInit2`, a macro over `inflateInit2_` in zlib.h); one `Z_FINISH` call inflates it all.
    private static func rawInflate(into target: UnsafeMutablePointer<UInt8>, capacity: Int,
                                   from source: UnsafePointer<UInt8>, count: Int) -> Int {
        guard let availableIn = uInt(exactly: count), let availableOut = uInt(exactly: capacity) else { return -1 }
        // SAFETY (each `unsafe` below): `stream` is a local that holds only the caller's two buffers, live for this
        // call, and zlib's own state, which inflateEnd frees before it goes out of scope. inflateInit2_ reads the
        // NUL-terminated version Swift makes for the call; zlib only reads through next_in (zlib.h: "next input
        // byte"), writes at most avail_out bytes at next_out and reads at most avail_in at next_in.
        var stream = unsafe z_stream()
        guard unsafe inflateInit2_(&stream, -MAX_WBITS, ZLIB_VERSION, Int32(clamping: MemoryLayout<z_stream>.size)) == Z_OK
        else { return -1 }
        defer { unsafe inflateEnd(&stream) }
        unsafe stream.next_in = UnsafeMutablePointer(mutating: source)
        unsafe stream.avail_in = availableIn
        unsafe stream.next_out = target
        unsafe stream.avail_out = availableOut
        guard unsafe CZlib.inflate(&stream, Z_FINISH) == Z_STREAM_END else { return -1 }
        return unsafe Int(exactly: stream.total_out) ?? -1
    }
    #endif
}
