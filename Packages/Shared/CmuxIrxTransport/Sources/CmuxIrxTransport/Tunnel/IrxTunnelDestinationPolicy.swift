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
        if let bytes = Self.parse(host, ipv6: false) {
            self = .v4(bytes)
            return
        }
        if let bytes = Self.parse(host, ipv6: true) {
            self = .v6(bytes)
            return
        }
        return nil
    }

    /// The address a kernel `in_addr` holds (`s_addr` is in network byte order).
    init(kernel address: in_addr) {
        let value = UInt32(bigEndian: address.s_addr)
        self = .v4([24, 16, 8, 0].map { UInt8(truncatingIfNeeded: value >> $0) })
    }

    /// The address a kernel `in6_addr` holds.
    init(kernel address: in6_addr) {
        // SAFETY: the view covers the 16 bytes of the local copy `address`, a plain
        // C struct with no padding, and Array copies them before the view ends.
        self = .v6(withUnsafeBytes(of: address) { unsafe Array($0) })
    }

    /// Canonical text (`inet_ntop`), usable as a connect target.
    public var text: String {
        switch self {
        case .v4(let bytes): Self.presentation(family: AF_INET, address: SIMD4<UInt8>(bytes))
        case .v6(let bytes): Self.presentation(family: AF_INET6, address: SIMD16<UInt8>(bytes))
        }
    }

    /// `inet_ntop` over a fixed-size address. Every case is built from exactly 4 or
    /// 16 bytes, so `SIMD4(bytes)` / `SIMD16(bytes)` trap when one is not, as a
    /// fixed-extent `base::span` CHECKs its size (Chromium base/containers/span.h).
    private static func presentation<Address: SIMD>(family: Int32, address: Address) -> String where Address.Scalar == UInt8 {
        var address = address
        var buffer = [CChar](repeating: 0, count: Int(clamping: INET6_ADDRSTRLEN))
        // SAFETY: inet_ntop reads 4 (AF_INET) or 16 (AF_INET6) bytes from `address`; `text`
        // passes a SIMD4<UInt8> with AF_INET and a SIMD16<UInt8> with AF_INET6, exactly that
        // many bytes. It writes at most buffer.count bytes, the size passed, NUL included.
        // Both outlive the call.
        guard unsafe inet_ntop(family, &address, &buffer, socklen_t(clamping: buffer.count)) != nil else { return "" }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// Network-order bytes of `host`, parsed strictly by inet_pton.
    private static func parse(_ host: String, ipv6: Bool) -> [UInt8]? {
        var bytes = [UInt8](repeating: 0, count: ipv6 ? 16 : 4)
        // SAFETY: inet_pton writes sizeof(struct in6_addr) (16) bytes for AF_INET6 and
        // sizeof(struct in_addr) (4) for AF_INET, exactly bytes.count. It reads the
        // NUL-terminated copy of `host` Swift makes for this call.
        guard unsafe inet_pton(ipv6 ? AF_INET6 : AF_INET, host, &bytes) == 1 else { return nil }
        return bytes
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
            let prefix = Array(bytes.prefix(12))
            let embeddedV4 = Array(bytes.dropFirst(12).prefix(4))
            if prefix == Array(repeating: 0, count: 10) + [0xFF, 0xFF]
                || prefix == [0x00, 0x64, 0xFF, 0x9B] + Array(repeating: 0, count: 8) {
                return Self.scopeV4(embeddedV4)
            }
            if prefix == Array(repeating: 0, count: 12) {
                if embeddedV4.allSatisfy({ $0 == 0 }) { return .loopback } // ::
                if embeddedV4 == [0, 0, 0, 1] { return .loopback } // ::1
                return Self.scopeV4(embeddedV4)
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
