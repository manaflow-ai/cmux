import NIOCore

/// SOCKS5 reply codes (RFC 1928 section 6).
public enum SocksReply: UInt8, Sendable {
    case succeeded = 0x00
    case generalFailure = 0x01
    case notAllowed = 0x02
    case networkUnreachable = 0x03
    case hostUnreachable = 0x04
    case connectionRefused = 0x05
    case ttlExpired = 0x06
    case commandNotSupported = 0x07
    case addressTypeNotSupported = 0x08

    func message(allocator: ByteBufferAllocator) -> ByteBuffer {
        // VER, REP, RSV, ATYP=IPv4, BND.ADDR 0.0.0.0, BND.PORT 0.
        var buffer = allocator.buffer(capacity: 10)
        buffer.writeBytes([0x05, rawValue, 0x00, 0x01, 0, 0, 0, 0, 0, 0])
        return buffer
    }
}

/// A parsed SOCKS5 request, or why it cannot be served.
public enum SocksParse: Equatable, Sendable {
    case needMoreData
    case greeting(acceptsNoAuth: Bool, consumed: Int)
    case connect(host: String, port: Int, consumed: Int)
    case reject(SocksReply)
    case malformed

    /// Largest greeting or request: a 255-byte domain name plus headers.
    static let maximumMessageByteCount = 4 + 1 + 255 + 2

    public static func greeting(_ bytes: [UInt8]) -> SocksParse {
        guard bytes.count >= 2 else { return .needMoreData }
        guard bytes[0] == 0x05 else { return .malformed }
        let count = Int(bytes[1])
        guard bytes.count >= 2 + count else { return .needMoreData }
        return .greeting(acceptsNoAuth: bytes[2..<(2 + count)].contains(0x00), consumed: 2 + count)
    }

    public static func request(_ bytes: [UInt8]) -> SocksParse {
        guard bytes.count >= 4 else { return .needMoreData }
        guard bytes[0] == 0x05 else { return .malformed }
        let host: String
        let addressEnd: Int
        switch bytes[3] {
        case 0x01:
            addressEnd = 4 + 4
            guard bytes.count >= addressEnd + 2 else { return .needMoreData }
            host = bytes[4..<addressEnd].map(String.init).joined(separator: ".")
        case 0x04:
            addressEnd = 4 + 16
            guard bytes.count >= addressEnd + 2 else { return .needMoreData }
            host = stride(from: 4, to: addressEnd, by: 2)
                .map { String(UInt16(bytes[$0]) << 8 | UInt16(bytes[$0 + 1]), radix: 16) }
                .joined(separator: ":")
        case 0x03:
            guard bytes.count >= 5 else { return .needMoreData }
            addressEnd = 5 + Int(bytes[4])
            guard bytes.count >= addressEnd + 2 else { return .needMoreData }
            host = String(decoding: bytes[5..<addressEnd], as: UTF8.self)
        default:
            return .reject(.addressTypeNotSupported)
        }
        // Only CONNECT; BIND and UDP ASSOCIATE are not offered.
        guard bytes[1] == 0x01 else { return .reject(.commandNotSupported) }
        let port = Int(bytes[addressEnd]) << 8 | Int(bytes[addressEnd + 1])
        guard !host.isEmpty, port > 0 else { return .reject(.hostUnreachable) }
        return .connect(host: host, port: port, consumed: addressEnd + 2)
    }
}
