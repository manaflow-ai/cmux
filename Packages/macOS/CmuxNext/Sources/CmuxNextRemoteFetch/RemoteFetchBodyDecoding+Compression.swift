#if canImport(Compression)
import Compression
import Foundation

/// The Apple half of ``RemoteFetchContentDecoding``: the system's Compression library decodes raw
/// DEFLATE (`COMPRESSION_ZLIB` reads it without framing) and Brotli.
extension RemoteFetchContentDecoding {
    /// The encodings the request offers, in its `Accept-Encoding` header.
    static let accepted = "gzip, deflate, br"

    /// Whether a `br` body is decoded here.
    static let decodesBrotli = true

    /// Decodes one raw stream of `format`, at most `maximumBody` bytes of output.
    static func decompress(_ input: Data.SubSequence, format: Format, maximumBody: Int) throws(RemoteFetchRefusal) -> Data {
        let algorithm = switch format {
        case .deflate: COMPRESSION_ZLIB
        case .brotli: COMPRESSION_BROTLI
        }
        let source = [UInt8](input)
        guard !source.isEmpty else { throw RemoteFetchRefusal(reason: "empty compressed body") }
        // SAFETY: `stream` is this call's own compression_stream, initialized before use, then destroyed and freed
        // once on return. Its source is `source`'s storage, lent by the outer closure for the whole decode, which
        // the stream reads src_size bytes of from src_ptr and advances through; each destination is `buffer`'s
        // storage, lent by the inner closure for the one compression_stream_process call that writes at most
        // dst_size = chunk = buffer.count bytes to it. No pointer is used after its closure returns.
        let stream = unsafe UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        defer { unsafe stream.deallocate() }
        guard unsafe compression_stream_init(stream, COMPRESSION_STREAM_DECODE, algorithm) == COMPRESSION_STATUS_OK else {
            throw RemoteFetchRefusal(reason: "decoder")
        }
        defer { unsafe compression_stream_destroy(stream) }
        let chunk = 64 * 1024
        var buffer = [UInt8](repeating: 0, count: chunk)
        var output = Data()
        var failure: RemoteFetchRefusal?
        unsafe source.withUnsafeBufferPointer { src in
            guard let base = unsafe src.baseAddress else { return }
            unsafe stream.pointee.src_ptr = base
            unsafe stream.pointee.src_size = src.count
            while failure == nil {
                let before = unsafe stream.pointee.src_size
                let (status, produced) = unsafe buffer.withUnsafeMutableBufferPointer { dst -> (compression_status, Int) in
                    guard let target = unsafe dst.baseAddress else { return (COMPRESSION_STATUS_ERROR, 0) }
                    unsafe stream.pointee.dst_ptr = target
                    unsafe stream.pointee.dst_size = chunk
                    let status = unsafe compression_stream_process(stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                    return unsafe (status, chunk - stream.pointee.dst_size)
                }
                let consumed = unsafe before - stream.pointee.src_size
                output.append(contentsOf: buffer[0..<produced])
                if output.count > maximumBody {
                    failure = RemoteFetchRefusal(reason: "decoded body over the cap", overCap: true)
                    break
                }
                switch status {
                case COMPRESSION_STATUS_END:
                    return
                case COMPRESSION_STATUS_OK where produced > 0 || consumed > 0:
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
