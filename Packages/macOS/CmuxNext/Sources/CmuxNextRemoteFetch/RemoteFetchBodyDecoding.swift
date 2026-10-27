import Foundation

/// Decodes an HTTP/1.1 `Transfer-Encoding: chunked` body as it arrives (RFC 9112 section 7.1):
/// hex size lines (extensions ignored), the chunk data with its CRLF, a zero chunk, then trailer
/// lines (dropped) up to an empty line. Refused: a size line over ``maximumLineBytes``, a size that
/// is not 1 to 15 hex digits (whitespace only around it), chunk data without its CRLF, trailers over ``maximumTrailerBytes``,
/// and data past `maximumBody` (``RemoteFetchRefusal/overCap``).
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
    mutating func append(_ data: Data) throws(RemoteFetchRefusal) -> Bool {
        pending.append(contentsOf: data)
        var cursor = 0
        defer { if cursor >= pending.count { pending.removeAll(keepingCapacity: true) } else { pending.removeFirst(cursor) } }
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
                        throw RemoteFetchRefusal(reason: "chunked body over the cap", overCap: true)
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
                    throw RemoteFetchRefusal(reason: "chunk without its CRLF")
                }
                cursor += 2
                state = .size
            case .trailer:
                guard let end = lineEnd(from: cursor) else { return try waitForLine(from: cursor) }
                trailerBytes += end - cursor + 2
                guard trailerBytes <= Self.maximumTrailerBytes else { throw RemoteFetchRefusal(reason: "trailers over 16 KB") }
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

    private func waitForLine(from start: Int) throws(RemoteFetchRefusal) -> Bool {
        guard pending.count - start <= Self.maximumLineBytes else { throw RemoteFetchRefusal(reason: "chunk line over 4 KB") }
        return false
    }

    private static func chunkSize(_ line: ArraySlice<UInt8>) throws(RemoteFetchRefusal) -> Int {
        let blank: (UInt8) -> Bool = { $0 == 0x20 || $0 == 0x09 }
        let field = line.prefix { $0 != UInt8(ascii: ";") }
        let digits = field.drop(while: blank).reversed().drop(while: blank).reversed()
        guard (1...15).contains(digits.count) else { throw RemoteFetchRefusal(reason: "chunk size") }
        var size = 0
        for byte in digits {
            let value: Int
            switch byte {
            case UInt8(ascii: "0")...UInt8(ascii: "9"): value = Int(byte - UInt8(ascii: "0"))
            case UInt8(ascii: "a")...UInt8(ascii: "f"): value = Int(byte - UInt8(ascii: "a")) + 10
            case UInt8(ascii: "A")...UInt8(ascii: "F"): value = Int(byte - UInt8(ascii: "A")) + 10
            default: throw RemoteFetchRefusal(reason: "chunk size")
            }
            size = size << 4 | value
        }
        return size
    }
}

/// Decodes a `Content-Encoding` the request offered (``accepted``), streaming, so a small body that
/// inflates past `maximumBody` stops at the cap (a decompression bomb is
/// ``RemoteFetchRefusal/overCap``). A stream that ends before its end marker is refused. The
/// framing (gzip header, zlib header) is read here; the raw stream goes to the platform's decoder,
/// ``decompress(_:format:maximumBody:)``: Apple's Compression library
/// (RemoteFetchBodyDecoding+Compression.swift) or zlib (RemoteFetchBodyDecoding+Zlib.swift).
nonisolated struct RemoteFetchContentDecoding {
    /// A compressed stream without its framing.
    enum Format: Equatable {
        /// Raw DEFLATE (RFC 1951): the body of a gzip or zlib stream.
        case deflate
        /// Brotli (RFC 7932).
        case brotli
    }

    /// The decoded body; `identity` or no encoding returns the body as is.
    static func decode(_ body: Data, encoding: String?, maximumBody: Int) throws(RemoteFetchRefusal) -> Data {
        let name = encoding?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
        switch name {
        case "", "identity":
            return body
        case "gzip", "x-gzip":
            return try decompress(body.dropFirst(try gzipHeaderLength(body)), format: .deflate, maximumBody: maximumBody)
        case "deflate":
            // Most servers send zlib framing (RFC 1950); some send raw DEFLATE, which the decoder reads.
            let bytes = [UInt8](body.prefix(2))
            let zlib = bytes.count == 2 && bytes[0] & 0x0f == 8 && bytes[0] >> 4 <= 7 && (Int(bytes[0]) << 8 | Int(bytes[1])) % 31 == 0
            if zlib, bytes[1] & 0x20 != 0 { throw RemoteFetchRefusal(reason: "deflate with a preset dictionary") }
            return try decompress(zlib ? body.dropFirst(2) : body[...], format: .deflate, maximumBody: maximumBody)
        case "br" where decodesBrotli:
            return try decompress(body[...], format: .brotli, maximumBody: maximumBody)
        default:
            throw RemoteFetchRefusal(reason: "Content-Encoding \(name)")
        }
    }

    /// The length of a gzip member header (RFC 1952): magic, method 8, flags, then the optional
    /// extra field, name, comment and header CRC.
    private static func gzipHeaderLength(_ body: Data) throws(RemoteFetchRefusal) -> Int {
        let bytes = [UInt8](body.prefix(64 * 1024))
        guard bytes.count >= 10, bytes[0] == 0x1f, bytes[1] == 0x8b, bytes[2] == 8 else {
            throw RemoteFetchRefusal(reason: "not a gzip stream")
        }
        let flags = bytes[3]
        var index = 10
        if flags & 0x04 != 0 {
            guard index + 2 <= bytes.count else { throw RemoteFetchRefusal(reason: "gzip header") }
            index += 2 + (Int(bytes[index]) | Int(bytes[index + 1]) << 8)
        }
        for flag in [UInt8(0x08), 0x10] where flags & flag != 0 {
            guard let zero = bytes[min(index, bytes.count)...].firstIndex(of: 0) else { throw RemoteFetchRefusal(reason: "gzip header") }
            index = zero + 1
        }
        if flags & 0x02 != 0 { index += 2 }
        guard index <= bytes.count else { throw RemoteFetchRefusal(reason: "gzip header") }
        return index
    }
}
