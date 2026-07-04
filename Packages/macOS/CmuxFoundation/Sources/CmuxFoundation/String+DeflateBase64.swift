import Compression
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
/// `deflatedBase64` compresses the UTF-8 bytes via `NSData`'s `.zlib`
/// algorithm and base64-encodes the result; a real shell script compresses
/// 5–13×, so the inlined literal shrinks proportionally.
/// `init?(deflatedBase64:)` reverses it with a bounded inflater. The format
/// never has to interoperate with command-line `gzip`.
extension String {
    /// This string zlib-compressed and base64-encoded, or `nil` for an empty string
    /// or if compression fails — so callers can fall back to a plain base64 literal.
    public var deflatedBase64: String? {
        let data = Data(utf8)
        guard !data.isEmpty,
              let compressed = try? (data as NSData).compressed(using: .zlib) as Data,
              !compressed.isEmpty else {
            return nil
        }
        return compressed.base64EncodedString()
    }

    /// Decode a payload produced by ``deflatedBase64`` — base64-decode then inflate.
    /// Fails (returns `nil`) if `encoded` is not valid base64 zlib-compressed UTF-8.
    ///
    /// - Parameter maxDecodedByteCount: Maximum accepted inflated byte count. The
    ///   default is 1 MiB, comfortably above cmux's SSH bootstrap payload while
    ///   keeping corrupted or crafted compressed argv values bounded.
    public init?(deflatedBase64 encoded: String, maxDecodedByteCount: Int = 1_048_576) {
        guard let compressed = Data(base64Encoded: encoded),
              !compressed.isEmpty,
              maxDecodedByteCount > 0,
              maxDecodedByteCount < Int.max else {
            return nil
        }

        let outputCapacity = maxDecodedByteCount + 1
        var output = [UInt8](repeating: 0, count: outputCapacity)
        let decodedByteCount = compressed.withUnsafeBytes { sourceBuffer in
            output.withUnsafeMutableBytes { destinationBuffer in
                guard let sourceBaseAddress = sourceBuffer.bindMemory(to: UInt8.self).baseAddress,
                      let destinationBaseAddress = destinationBuffer.bindMemory(to: UInt8.self).baseAddress else {
                    return 0
                }
                return compression_decode_buffer(
                    destinationBaseAddress,
                    outputCapacity,
                    sourceBaseAddress,
                    compressed.count,
                    nil,
                    COMPRESSION_ZLIB
                )
            }
        }

        let decodedData = Data(output.prefix(decodedByteCount))
        guard decodedByteCount > 0,
              decodedByteCount <= maxDecodedByteCount,
              compressed.isCanonicalDeflatedForm(for: decodedData),
              let string = String(data: decodedData, encoding: .utf8) else {
            return nil
        }
        self = string
    }
}

private extension Data {
    func isCanonicalDeflatedForm(for decodedData: Data) -> Bool {
        guard let recompressed = try? (decodedData as NSData).compressed(using: .zlib) as Data else {
            return false
        }
        return recompressed == self
    }
}
