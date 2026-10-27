#if !canImport(Compression)
import CZlib
import Foundation

/// The half of ``RemoteFetchContentDecoding`` for systems without Apple's Compression library: zlib
/// inflates raw DEFLATE (a negative window size, zlib's raw mode), as Chromium's
/// net/filter/gzip_source_stream.cc does once it has read the framing. zlib has no Brotli, so the
/// request does not offer `br` and a `br` reply is refused.
extension RemoteFetchContentDecoding {
    /// The encodings the request offers, in its `Accept-Encoding` header.
    static let accepted = "gzip, deflate"

    /// Whether a `br` body is decoded here.
    static let decodesBrotli = false

    /// Decodes one raw stream of `format`, at most `maximumBody` bytes of output.
    static func decompress(_ input: Data.SubSequence, format: Format, maximumBody: Int) throws(RemoteFetchRefusal) -> Data {
        guard format == .deflate else { throw RemoteFetchRefusal(reason: "Content-Encoding br") }
        var source = [UInt8](input)
        guard !source.isEmpty else { throw RemoteFetchRefusal(reason: "empty compressed body") }
        guard let available = uInt(exactly: source.count) else { throw RemoteFetchRefusal(reason: "compressed body over 4 GB") }
        // SAFETY: `stream` is this call's own z_stream: zeroed (zlib's default allocator), initialized by
        // inflateInit2_ before use and ended once on return. Its input is `source`'s storage, lent by the outer
        // closure for the whole decode, which inflate reads avail_in bytes of from next_in and advances through;
        // each output is `buffer`'s storage, lent by the inner closure for the one inflate call that writes at most
        // avail_out = chunk = buffer.count bytes to it. No pointer is used after its closure returns.
        var stream = unsafe z_stream()
        guard unsafe inflateInit2_(&stream, -MAX_WBITS, zlibVersion(), Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            throw RemoteFetchRefusal(reason: "decoder")
        }
        defer { unsafe inflateEnd(&stream) }
        let chunk = 64 * 1024
        var buffer = [UInt8](repeating: 0, count: chunk)
        var output = Data()
        var failure: RemoteFetchRefusal?
        unsafe source.withUnsafeMutableBufferPointer { src in
            guard let base = src.baseAddress else { return }
            unsafe stream.next_in = base
            unsafe stream.avail_in = available
            while failure == nil {
                let before = unsafe stream.avail_in
                let (status, produced) = unsafe buffer.withUnsafeMutableBufferPointer { dst -> (Int32, Int) in
                    guard let target = dst.baseAddress else { return (Z_STREAM_ERROR, 0) }
                    unsafe stream.next_out = target
                    unsafe stream.avail_out = uInt(chunk)
                    let status = unsafe inflate(&stream, Z_NO_FLUSH)
                    return unsafe (status, chunk - Int(stream.avail_out))
                }
                let consumed = unsafe before - stream.avail_in
                output.append(contentsOf: buffer[0..<produced])
                if output.count > maximumBody {
                    failure = RemoteFetchRefusal(reason: "decoded body over the cap", overCap: true)
                    break
                }
                switch status {
                case Z_STREAM_END:
                    return
                case Z_OK where produced > 0 || consumed > 0:
                    continue
                default:
                    // An error, or no progress with all input given: a cut or corrupt stream.
                    failure = RemoteFetchRefusal(reason: "corrupt or truncated compressed body")
                }
            }
        }
        if let failure { throw failure }
        return output
    }
}
#endif
