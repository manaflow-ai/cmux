import Compression
import Foundation

/// Inflates a compressed `snapshot {phase: "history"}` chunk
/// (`terminal-snapshot-history-v1`). The host compresses each chunk on its
/// own, so each inflates alone. Runs on the attach reader thread, never the
/// main thread.
enum TerminalSnapshotInflate {
    /// `compression` values this view inflates. `deflate` is raw DEFLATE
    /// (RFC 1951, no zlib or gzip framing), what COMPRESSION_ZLIB reads.
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
        let written = out.withUnsafeMutableBytes { dst -> Int in
            data.withUnsafeBytes { src -> Int in
                guard let target = dst.bindMemory(to: UInt8.self).baseAddress,
                      let source = src.bindMemory(to: UInt8.self).baseAddress else { return -1 }
                return compression_decode_buffer(target, rawBytes + 1, source, data.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard written == rawBytes else { return nil }
        out.removeLast()
        return out
    }
}
