import Foundation
import NIOCore

/// Credentials for the optional RFC 1929 SOCKS5 username/password method.
///
/// A route that exposes a SOCKS listener on the phone's shared loopback must
/// opt into credentials. The no-auth mode remains available for callers that
/// already isolate their listener by some other means.
public struct SocksCredential: Hashable, Sendable {
    public let username: String
    public let password: String

    public init(username: String, password: String) {
        self.username = username
        self.password = password
    }

    /// Generates an opaque per-listener credential. It is intentionally not
    /// persisted; stopping a route invalidates it.
    public static func random() -> SocksCredential {
        var generator = SystemRandomNumberGenerator()
        func token() -> String {
            let bytes = (0..<24).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
            return Data(bytes).base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }
        return SocksCredential(username: token(), password: token())
    }

    /// Constant-time comparison for credentials received from a local client.
    public func matches(username: String, password: String) -> Bool {
        Self.constantTimeEquals(username, self.username) && Self.constantTimeEquals(password, self.password)
    }

    private static func constantTimeEquals(_ lhs: String, _ rhs: String) -> Bool {
        let a = Array(lhs.utf8)
        let b = Array(rhs.utf8)
        guard a.count == b.count else { return false }
        var difference: UInt8 = 0
        for index in a.indices { difference |= a[index] ^ b[index] }
        return difference == 0
    }
}

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
    case authentication(username: String, password: String, consumed: Int)
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

    /// Parses the RFC 1929 username/password sub-negotiation. The caller
    /// decides whether the credentials match its route's secret.
    public static func authentication(_ bytes: [UInt8]) -> SocksParse {
        guard bytes.count >= 2 else { return .needMoreData }
        guard bytes[0] == 0x01 else { return .malformed }
        let usernameLength = Int(bytes[1])
        let passwordLengthOffset = 2 + usernameLength
        guard bytes.count >= passwordLengthOffset + 1 else { return .needMoreData }
        let passwordLength = Int(bytes[passwordLengthOffset])
        let end = passwordLengthOffset + 1 + passwordLength
        guard bytes.count >= end else { return .needMoreData }
        let username = String(decoding: bytes[2..<passwordLengthOffset], as: UTF8.self)
        let passwordStart = passwordLengthOffset + 1
        let password = String(decoding: bytes[passwordStart..<end], as: UTF8.self)
        return .authentication(username: username, password: password, consumed: end)
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
