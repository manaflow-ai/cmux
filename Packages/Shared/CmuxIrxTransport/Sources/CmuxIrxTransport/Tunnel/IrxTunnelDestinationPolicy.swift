import Darwin
import Foundation

/// A literal IP address, parsed strictly (`inet_pton`: dotted quads and
/// standard IPv6 only, so `127.1` or `0x7f.0.0.1` are names, not addresses).
public enum IrxTunnelIPAddress: Hashable, Sendable {
    case v4([UInt8])
    case v6([UInt8])

    public init?(_ text: String) {
        var host = text
        if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        var v4 = in_addr()
        if inet_pton(AF_INET, host, &v4) == 1 {
            self = .v4(withUnsafeBytes(of: &v4) { Array($0) })
            return
        }
        var v6 = in6_addr()
        if inet_pton(AF_INET6, host, &v6) == 1 {
            self = .v6(withUnsafeBytes(of: &v6) { Array($0) })
            return
        }
        return nil
    }

    /// Canonical text (`inet_ntop`), usable as a connect target.
    public var text: String {
        var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        switch self {
        case .v4(let bytes):
            var address = in_addr()
            withUnsafeMutableBytes(of: &address) { $0.copyBytes(from: bytes) }
            inet_ntop(AF_INET, &address, &buffer, socklen_t(buffer.count))
        case .v6(let bytes):
            var address = in6_addr()
            withUnsafeMutableBytes(of: &address) { $0.copyBytes(from: bytes) }
            inet_ntop(AF_INET6, &address, &buffer, socklen_t(buffer.count))
        }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    public static let loopbackV4 = IrxTunnelIPAddress.v4([127, 0, 0, 1])
    public static let loopbackV6 = IrxTunnelIPAddress.v6(Array(repeating: 0, count: 15) + [1])

    /// Where a connection to this address would go.
    public enum Scope: Equatable, Sendable {
        /// This Mac (`127/8`, `::1`, and the unspecified address, which
        /// connects to the local host).
        case loopback
        /// Any other unicast host (LAN, VPN, internet).
        case remote
        /// Never reachable through the tunnel: link-local (including the
        /// cloud metadata service at 169.254.169.254), multicast, broadcast,
        /// reserved, and known metadata addresses outside link-local.
        case forbidden
    }

    public var scope: Scope {
        switch self {
        case .v4(let bytes):
            return Self.scopeV4(bytes)
        case .v6(let bytes):
            // IPv4-mapped (::ffff:a.b.c.d), IPv4-compatible (::a.b.c.d), and
            // NAT64 (64:ff9b::a.b.c.d) addresses reach the embedded IPv4.
            let prefix = Array(bytes[0..<12])
            if prefix == Array(repeating: 0, count: 10) + [0xFF, 0xFF]
                || prefix == [0x00, 0x64, 0xFF, 0x9B] + Array(repeating: 0, count: 8) {
                return Self.scopeV4(Array(bytes[12..<16]))
            }
            if prefix == Array(repeating: 0, count: 12) {
                if bytes[12..<16].allSatisfy({ $0 == 0 }) { return .loopback } // ::
                if bytes[12..<15].allSatisfy({ $0 == 0 }), bytes[15] == 1 { return .loopback } // ::1
                return Self.scopeV4(Array(bytes[12..<16]))
            }
            if bytes[0] == 0xFE, bytes[1] & 0xC0 == 0x80 { return .forbidden } // fe80::/10 link-local
            if bytes[0] == 0xFE, bytes[1] & 0xC0 == 0xC0 { return .forbidden } // fec0::/10 site-local
            if bytes[0] == 0xFF { return .forbidden } // multicast
            // AWS instance metadata over IPv6.
            if self == IrxTunnelIPAddress("fd00:ec2::254") { return .forbidden }
            return .remote
        }
    }

    private static func scopeV4(_ bytes: [UInt8]) -> Scope {
        let a = bytes[0], b = bytes[1]
        if bytes == [0, 0, 0, 0] { return .loopback }
        if a == 127 { return .loopback }
        if a == 0 { return .forbidden } // "this network"
        if a == 169, b == 254 { return .forbidden } // link-local, cloud metadata
        if a >= 224 { return .forbidden } // multicast, reserved, broadcast
        if bytes == [100, 100, 100, 200] { return .forbidden } // Alibaba Cloud metadata
        return .remote
    }

    /// The address to connect to: the unspecified address means this host.
    var connectTarget: IrxTunnelIPAddress {
        switch self {
        case .v4([0, 0, 0, 0]): return .loopbackV4
        case .v6(let bytes) where bytes.allSatisfy({ $0 == 0 }): return .loopbackV6
        default: return self
        }
    }
}

/// Which destinations the phone browser tunnel may reach from this Mac.
///
/// Default deny: only this Mac's loopback (`localhost`, `*.localhost`,
/// `127.0.0.0/8`, `::1`). Other hosts need the Mac-side opt-in
/// (`mobile.browserTunnel.allowOtherHosts`), and even then link-local and
/// metadata addresses are refused. A host name is resolved on the Mac and
/// every resolved address is checked, and the connection goes to a checked
/// address, so a name cannot rebind past the policy between check and use.
public struct IrxTunnelDestinationPolicy: Equatable, Sendable {
    public var allowsNonLoopbackHosts: Bool

    public init(allowsNonLoopbackHosts: Bool) {
        self.allowsNonLoopbackHosts = allowsNonLoopbackHosts
    }

    public enum Verdict: Equatable, Sendable {
        /// Connect to these addresses in order (no DNS).
        case connect([IrxTunnelIPAddress])
        /// Resolve this name on the Mac, then filter with `permits`.
        case resolve(String)
        case deny
    }

    public func evaluate(host rawHost: String, port: Int) -> Verdict {
        guard (1...65_535).contains(port) else { return .deny }
        var host = rawHost.lowercased()
        if host.hasSuffix(".") { host.removeLast() }
        guard !host.isEmpty, host.utf8.count <= 253 else { return .deny }
        if let address = IrxTunnelIPAddress(host) {
            return permits(address) ? .connect([address.connectTarget]) : .deny
        }
        // RFC 6761: `localhost` and every `*.localhost` name are this host.
        // Answered here, never by DNS, so no resolver can redirect them.
        if host == "localhost" || host.hasSuffix(".localhost") {
            return .connect([.loopbackV4, .loopbackV6])
        }
        // Anything else that looks like a literal (a scope id, a bracketed
        // form inet_pton rejected) is not a name either.
        guard allowsNonLoopbackHosts, !host.contains("%"), !host.contains("["), !host.contains("/") else {
            return .deny
        }
        return .resolve(host)
    }

    /// Whether a (literal or resolved) address may be connected to.
    public func permits(_ address: IrxTunnelIPAddress) -> Bool {
        switch address.scope {
        case .loopback: return true
        case .remote: return allowsNonLoopbackHosts
        case .forbidden: return false
        }
    }

    /// The resolved addresses a connection may use, in resolver order.
    public func filterResolved(_ addresses: [IrxTunnelIPAddress]) -> [IrxTunnelIPAddress] {
        var seen = Set<IrxTunnelIPAddress>()
        return addresses.filter(permits).map(\.connectTarget).filter { seen.insert($0).inserted }
    }
}
