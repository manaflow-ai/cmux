import Compression
import Foundation

/// Decodes an HTTP/1.1 `Transfer-Encoding: chunked` body as it arrives (RFC 9112 section 7.1):
/// hex size lines (extensions ignored), the chunk data with its CRLF, a zero chunk, then trailer
/// lines (dropped) up to an empty line. Refused: a size line over ``maximumLineBytes``, a size that
/// is not 1 to 15 hex digits (whitespace only around it), chunk data without its CRLF, trailers over ``maximumTrailerBytes``,
/// and data past `maximumBody` (``RemoteFetchReplyReader/Refusal/overCap``).
nonisolated struct RemoteFetchChunkedBody {
    static let maximumLineBytes = 4 * 1024
    static let maximumTrailerBytes = 16 * 1024

    private nonisolated enum State {
        case size
        case data(remaining: Int)
        case dataEnd
        case trailer
        case done
    }

    let maximumBody: Int
    private(set) var output = Data()
    private var state = State.size
    private var pending: [UInt8] = []
    private var trailerBytes = 0

    init(maximumBody: Int) {
        self.maximumBody = maximumBody
    }

    var isComplete: Bool {
        if case .done = state { return true }
        return false
    }

    /// Adds wire bytes; true once the zero chunk and the trailers have arrived.
    mutating func append(_ data: Data) throws(RemoteFetchReplyReader.Refusal) -> Bool {
        pending.append(contentsOf: data)
        var cursor = 0
        defer { pending.removeFirst(cursor) }
        // Each pass consumes received bytes or returns to wait for more.
        while !isComplete {
            switch state {
            case .done:
                return true
            case .size:
                guard let end = lineEnd(from: cursor) else { return try waitForLine(from: cursor) }
                let size = try Self.chunkSize(pending[cursor..<end])
                cursor = end + 2
                if size == 0 {
                    state = .trailer
                } else {
                    guard output.count + size <= maximumBody else {
                        throw RemoteFetchReplyReader.Refusal(reason: "chunked body over the cap", overCap: true)
                    }
                    state = .data(remaining: size)
                }
            case .data(let remaining):
                let take = min(remaining, pending.count - cursor)
                guard take > 0 else { return false }
                output.append(contentsOf: pending[cursor..<cursor + take])
                cursor += take
                state = remaining == take ? .dataEnd : .data(remaining: remaining - take)
            case .dataEnd:
                guard pending.count - cursor >= 2 else { return false }
                guard pending[cursor] == 0x0d, pending[cursor + 1] == 0x0a else {
                    throw RemoteFetchReplyReader.Refusal(reason: "chunk without its CRLF")
                }
                cursor += 2
                state = .size
            case .trailer:
                guard let end = lineEnd(from: cursor) else { return try waitForLine(from: cursor) }
                trailerBytes += end - cursor + 2
                guard trailerBytes <= Self.maximumTrailerBytes else { throw RemoteFetchReplyReader.Refusal(reason: "trailers over 16 KB") }
                let empty = end == cursor
                cursor = end + 2
                if empty { state = .done }
            }
        }
        return true
    }

    private func lineEnd(from start: Int) -> Int? {
        var index = start
        while index + 1 < pending.count {
            if pending[index] == 0x0d, pending[index + 1] == 0x0a { return index }
            index += 1
        }
        return nil
    }

    private func waitForLine(from start: Int) throws(RemoteFetchReplyReader.Refusal) -> Bool {
        guard pending.count - start <= Self.maximumLineBytes else { throw RemoteFetchReplyReader.Refusal(reason: "chunk line over 4 KB") }
        return false
    }

    private static func chunkSize(_ line: ArraySlice<UInt8>) throws(RemoteFetchReplyReader.Refusal) -> Int {
        let blank: (UInt8) -> Bool = { $0 == 0x20 || $0 == 0x09 }
        let field = line.prefix { $0 != UInt8(ascii: ";") }
        let digits = field.drop(while: blank).reversed().drop(while: blank).reversed()
        guard (1...15).contains(digits.count) else { throw RemoteFetchReplyReader.Refusal(reason: "chunk size") }
        var size = 0
        for byte in digits {
            let value: Int
            switch byte {
            case UInt8(ascii: "0")...UInt8(ascii: "9"): value = Int(byte - UInt8(ascii: "0"))
            case UInt8(ascii: "a")...UInt8(ascii: "f"): value = Int(byte - UInt8(ascii: "a")) + 10
            case UInt8(ascii: "A")...UInt8(ascii: "F"): value = Int(byte - UInt8(ascii: "A")) + 10
            default: throw RemoteFetchReplyReader.Refusal(reason: "chunk size")
            }
            size = size << 4 | value
        }
        return size
    }
}

/// Decodes a `Content-Encoding` the request offered (`gzip`, `deflate`, `br`) with the system's
/// Compression library, streaming, so a small body that inflates past `maximumBody` stops at the
/// cap (a decompression bomb is ``RemoteFetchReplyReader/Refusal/overCap``). A stream that ends
/// before its end marker is refused.
nonisolated struct RemoteFetchContentDecoding {
    /// The encodings the request offers, in its `Accept-Encoding` header.
    static let accepted = "gzip, deflate, br"

    /// The decoded body; `identity` or no encoding returns the body as is.
    static func decode(_ body: Data, encoding: String?, maximumBody: Int) throws(RemoteFetchReplyReader.Refusal) -> Data {
        let name = encoding?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
        switch name {
        case "", "identity":
            return body
        case "gzip", "x-gzip":
            return try inflate(body.dropFirst(try gzipHeaderLength(body)), algorithm: COMPRESSION_ZLIB, maximumBody: maximumBody)
        case "deflate":
            // Most servers send zlib framing (RFC 1950); some send raw DEFLATE. COMPRESSION_ZLIB reads raw.
            let bytes = [UInt8](body.prefix(2))
            let zlib = bytes.count == 2 && bytes[0] & 0x0f == 8 && bytes[0] >> 4 <= 7 && (Int(bytes[0]) << 8 | Int(bytes[1])) % 31 == 0
            if zlib, bytes[1] & 0x20 != 0 { throw RemoteFetchReplyReader.Refusal(reason: "deflate with a preset dictionary") }
            return try inflate(zlib ? body.dropFirst(2) : body[...], algorithm: COMPRESSION_ZLIB, maximumBody: maximumBody)
        case "br":
            return try inflate(body[...], algorithm: COMPRESSION_BROTLI, maximumBody: maximumBody)
        default:
            throw RemoteFetchReplyReader.Refusal(reason: "Content-Encoding \(name)")
        }
    }

    /// The length of a gzip member header (RFC 1952): magic, method 8, flags, then the optional
    /// extra field, name, comment and header CRC.
    private static func gzipHeaderLength(_ body: Data) throws(RemoteFetchReplyReader.Refusal) -> Int {
        let bytes = [UInt8](body.prefix(64 * 1024))
        guard bytes.count >= 10, bytes[0] == 0x1f, bytes[1] == 0x8b, bytes[2] == 8 else {
            throw RemoteFetchReplyReader.Refusal(reason: "not a gzip stream")
        }
        let flags = bytes[3]
        var index = 10
        if flags & 0x04 != 0 {
            guard index + 2 <= bytes.count else { throw RemoteFetchReplyReader.Refusal(reason: "gzip header") }
            index += 2 + (Int(bytes[index]) | Int(bytes[index + 1]) << 8)
        }
        for flag in [UInt8(0x08), 0x10] where flags & flag != 0 {
            guard let zero = bytes[min(index, bytes.count)...].firstIndex(of: 0) else { throw RemoteFetchReplyReader.Refusal(reason: "gzip header") }
            index = zero + 1
        }
        if flags & 0x02 != 0 { index += 2 }
        guard index <= bytes.count else { throw RemoteFetchReplyReader.Refusal(reason: "gzip header") }
        return index
    }

    private static func inflate(_ input: Data.SubSequence, algorithm: compression_algorithm, maximumBody: Int) throws(RemoteFetchReplyReader.Refusal) -> Data {
        let source = [UInt8](input)
        guard !source.isEmpty else { throw RemoteFetchReplyReader.Refusal(reason: "empty compressed body") }
        let stream = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        defer { stream.deallocate() }
        guard compression_stream_init(stream, COMPRESSION_STREAM_DECODE, algorithm) == COMPRESSION_STATUS_OK else {
            throw RemoteFetchReplyReader.Refusal(reason: "decoder")
        }
        defer { compression_stream_destroy(stream) }
        let chunk = 64 * 1024
        var buffer = [UInt8](repeating: 0, count: chunk)
        var output = Data()
        var failure: RemoteFetchReplyReader.Refusal?
        source.withUnsafeBufferPointer { src in
            guard let base = src.baseAddress else { return }
            stream.pointee.src_ptr = base
            stream.pointee.src_size = src.count
            while failure == nil {
                let before = stream.pointee.src_size
                let (status, produced) = buffer.withUnsafeMutableBufferPointer { dst -> (compression_status, Int) in
                    guard let target = dst.baseAddress else { return (COMPRESSION_STATUS_ERROR, 0) }
                    stream.pointee.dst_ptr = target
                    stream.pointee.dst_size = chunk
                    let status = compression_stream_process(stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                    return (status, chunk - stream.pointee.dst_size)
                }
                let consumed = before - stream.pointee.src_size
                output.append(contentsOf: buffer[0..<produced])
                if output.count > maximumBody {
                    failure = RemoteFetchReplyReader.Refusal(reason: "decoded body over the cap", overCap: true)
                    break
                }
                switch status {
                case COMPRESSION_STATUS_END:
                    return
                case COMPRESSION_STATUS_OK where produced > 0 || consumed > 0:
                    continue
                default:
                    // An error, or no progress with all input given: a cut or corrupt stream.
                    failure = RemoteFetchReplyReader.Refusal(reason: "corrupt or truncated compressed body")
                }
            }
        }
        if let failure { throw failure }
        return output
    }
}
