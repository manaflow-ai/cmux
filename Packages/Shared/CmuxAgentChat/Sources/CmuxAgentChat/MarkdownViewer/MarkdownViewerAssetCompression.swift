import Foundation
import zlib

/// Inflates the zlib-deflated markdown viewer JS assets produced by
/// `scripts/compress-markdown-viewer-assets.sh` at build time. Shared by the
/// macOS and iOS asset loaders so both bundles use the identical format.
public enum MarkdownViewerAssetCompression {
    public static func inflate(_ data: Data) -> Data? {
        guard !data.isEmpty else {
            return Data()
        }

        var stream = z_stream()
        let initResult = inflateInit_(
            &stream,
            ZLIB_VERSION,
            Int32(MemoryLayout<z_stream>.size)
        )
        guard initResult == Z_OK else {
            return nil
        }
        defer { inflateEnd(&stream) }

        return data.withUnsafeBytes { inputBuffer in
            guard let inputBase = inputBuffer.bindMemory(to: Bytef.self).baseAddress else {
                return nil
            }
            stream.next_in = UnsafeMutablePointer<Bytef>(mutating: inputBase)
            stream.avail_in = uInt(data.count)

            var output = Data()
            let chunkSize = 64 * 1024
            var chunk = [UInt8](repeating: 0, count: chunkSize)

            while true {
                let result = chunk.withUnsafeMutableBytes { outputBuffer -> Int32 in
                    stream.next_out = outputBuffer.bindMemory(to: Bytef.self).baseAddress
                    stream.avail_out = uInt(chunkSize)
                    return zlib.inflate(&stream, Z_NO_FLUSH)
                }

                let produced = chunkSize - Int(stream.avail_out)
                if produced > 0 {
                    output.append(chunk, count: produced)
                }

                if result == Z_STREAM_END {
                    return output
                }
                if result != Z_OK {
                    return nil
                }
                if stream.avail_in == 0 && produced == 0 {
                    return nil
                }
            }
        }
    }
}
