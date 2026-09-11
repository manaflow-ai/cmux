import Foundation
import Network

/// The client half of the SOCKS5 subset the cmux-tui WireGuard hub speaks
/// (RFC 1928: CONNECT, the "no authentication" method, literal IP targets).
///
/// A pure byte codec: it never touches a socket, so the forwarder's protocol
/// handling is testable on its own. The hub deliberately supports nothing else
/// (no domain names, no other commands), so a hostname is refused here rather
/// than sent in a request the hub would reject.
enum SocksV5Client {
    enum ClientError: Error, Equatable, LocalizedError {
        /// The target is not a literal IPv4 or IPv6 address.
        case unsupportedHost(String)
        case serverVersion(UInt8)
        case methodRejected(UInt8)
        case malformedReply
        /// The hub answered CONNECT with a failure; `code` is the RFC 1928 reply.
        case connectFailed(code: UInt8)

        var errorDescription: String? {
            switch self {
            case .unsupportedHost(let host):
                return "\(host) is not a literal IP address; the Cloud hub only forwards to VM addresses."
            case .serverVersion(let version):
                return "The Cloud hub answered with SOCKS version \(version)."
            case .methodRejected(let method):
                return "The Cloud hub rejected the SOCKS handshake (method 0x\(String(method, radix: 16)))."
            case .malformedReply:
                return "The Cloud hub sent a malformed SOCKS reply."
            case .connectFailed(let code):
                return "The Cloud hub could not reach the VM port: \(SocksV5Client.replyDescription(code))."
            }
        }
    }

    static let version: UInt8 = 0x05
    static let methodNoAuthentication: UInt8 = 0x00
    static let commandConnect: UInt8 = 0x01
    static let addressTypeIPv4: UInt8 = 0x01
    static let addressTypeDomain: UInt8 = 0x03
    static let addressTypeIPv6: UInt8 = 0x04
    static let replySucceeded: UInt8 = 0x00

    /// Version 5, one offered method: no authentication (the hub checks the
    /// socket peer's uid instead).
    static let greeting: [UInt8] = [version, 0x01, methodNoAuthentication]
    /// `VER METHOD`.
    static let methodSelectionLength = 2
    /// `VER REP RSV ATYP`; the bound address and port follow.
    static let replyHeaderLength = 4

    /// `VER CMD RSV ATYP DST.ADDR DST.PORT` for a literal IPv4 or IPv6 `host`.
    static func connectRequest(host: String, port: Int) throws -> [UInt8] {
        guard (1...65_535).contains(port) else { throw ClientError.unsupportedHost("\(host):\(port)") }
        var request: [UInt8] = [version, commandConnect, 0x00]
        if let ipv4 = IPv4Address(host) {
            request.append(addressTypeIPv4)
            request.append(contentsOf: ipv4.rawValue)
        } else if let ipv6 = IPv6Address(host) {
            request.append(addressTypeIPv6)
            request.append(contentsOf: ipv6.rawValue)
        } else {
            throw ClientError.unsupportedHost(host)
        }
        request.append(UInt8(port >> 8))
        request.append(UInt8(port & 0xFF))
        return request
    }

    /// Validates the server's `VER METHOD` answer to ``greeting``.
    static func checkMethodSelection(_ bytes: [UInt8]) throws {
        guard bytes.count == methodSelectionLength else { throw ClientError.malformedReply }
        guard bytes[0] == version else { throw ClientError.serverVersion(bytes[0]) }
        guard bytes[1] == methodNoAuthentication else { throw ClientError.methodRejected(bytes[1]) }
    }

    /// The number of bytes that follow a reply's four-byte `header` (the bound
    /// address and port), or nil for a domain-typed reply, whose length byte
    /// comes next; see ``domainReplyTrailerLength(lengthByte:)``.
    static func replyTrailerLength(header: [UInt8]) throws -> Int? {
        guard header.count == replyHeaderLength else { throw ClientError.malformedReply }
        switch header[3] {
        case addressTypeIPv4: return 4 + 2
        case addressTypeIPv6: return 16 + 2
        case addressTypeDomain: return nil
        default: throw ClientError.malformedReply
        }
    }

    /// The bytes that follow a domain-typed reply's length byte: the name and
    /// the two-byte port.
    static func domainReplyTrailerLength(lengthByte: UInt8) -> Int {
        Int(lengthByte) + 2
    }

    /// Validates a complete CONNECT reply.
    static func checkReply(_ bytes: [UInt8]) throws {
        guard bytes.count >= replyHeaderLength else { throw ClientError.malformedReply }
        guard bytes[0] == version else { throw ClientError.serverVersion(bytes[0]) }
        guard bytes[1] == replySucceeded else { throw ClientError.connectFailed(code: bytes[1]) }
        guard bytes[2] == 0x00 else { throw ClientError.malformedReply }
    }

    /// RFC 1928 reply codes, as the pane's failure text.
    static func replyDescription(_ code: UInt8) -> String {
        switch code {
        case 0x00: return "succeeded"
        case 0x01: return "general failure"
        case 0x02: return "connection not allowed by ruleset"
        case 0x03: return "network unreachable"
        case 0x04: return "host unreachable"
        case 0x05: return "connection refused"
        case 0x06: return "TTL expired"
        case 0x07: return "command not supported"
        case 0x08: return "address type not supported"
        default: return "reply code 0x\(String(code, radix: 16))"
        }
    }
}
