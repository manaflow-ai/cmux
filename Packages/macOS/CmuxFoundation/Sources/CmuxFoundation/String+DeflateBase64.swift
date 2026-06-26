import Foundation

/// Compact codec for strings that would otherwise be inlined into process `argv`
/// as a large base64 literal.
///
/// SSH terminal startup commands carry the remote bootstrap script (≈150 KB of
/// bundled shell integration) so the surface command can recreate it after a
/// reconnect or session restore. Inlining it as raw base64 pushes a single
/// `cmux ssh-pty-attach` invocation — and the `/bin/sh -c` wrapper that embeds
/// it, carried twice across the surface's `login`/`sh` layers — past a megabyte
/// of `argv`. That bloats `ps aux` output enough to break tools that scan the
/// process table with a bounded buffer (see manaflow-ai/cmux#6738).
///
/// `deflatedBase64` raw-DEFLATEs the UTF-8 bytes (RFC 1951, via `NSData`'s
/// `.zlib` algorithm) and base64-encodes the result; a real shell script
/// compresses 5–13×, so the inlined literal shrinks proportionally.
/// `init?(deflatedBase64:)` reverses it. Both ends run the same Foundation API,
/// so the format never has to interoperate with command-line `gzip`.
public extension String {
    /// This string raw-DEFLATEd and base64-encoded, or `nil` for an empty string
    /// or if compression fails — so callers can fall back to a plain base64 literal.
    var deflatedBase64: String? {
        let data = Data(utf8)
        guard !data.isEmpty,
              let compressed = try? (data as NSData).compressed(using: .zlib) as Data,
              !compressed.isEmpty else {
            return nil
        }
        return compressed.base64EncodedString()
    }

    /// Decode a payload produced by ``deflatedBase64`` — base64-decode then inflate.
    /// Fails (returns `nil`) if `encoded` is not valid base64 raw-DEFLATE UTF-8.
    init?(deflatedBase64 encoded: String) {
        guard let compressed = Data(base64Encoded: encoded),
              !compressed.isEmpty,
              let data = try? (compressed as NSData).decompressed(using: .zlib) as Data,
              let string = String(data: data, encoding: .utf8) else {
            return nil
        }
        self = string
    }
}
