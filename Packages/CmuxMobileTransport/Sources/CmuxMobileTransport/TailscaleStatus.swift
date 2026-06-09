import Foundation

/// Whether this device currently has an active Tailscale tailnet route.
///
/// Detection is an interface heuristic: an active Tailscale tunnel gives the
/// device a `utun` interface whose self-address sits in the Tailscale CGNAT
/// range `100.64.0.0/10` or the Tailscale IPv6 ULA `fd7a:115c:a1e0::/48`.
/// The Tailscale iOS app declares no URL scheme
/// (https://github.com/tailscale/tailscale/issues/14679), so the app cannot
/// ask the OS whether Tailscale is installed. That limit is modeled honestly:
/// there is no "not installed" case, only ``inactiveOrNotInstalled``.
public enum TailscaleStatus: Sendable, Equatable {
    /// A tunnel interface currently holds a Tailscale-range self address.
    case active
    /// No tailnet address was found. iOS cannot distinguish "Tailscale is not
    /// installed" from "installed but switched off"; both land here.
    case inactiveOrNotInstalled
    /// Interface enumeration failed, so no claim is made either way.
    case unknown
}

/// One numeric self-address of one network interface, as enumerated from the
/// system. A plain value type so classification logic is testable with
/// injected fixtures.
public struct NetworkInterfaceAddress: Sendable, Equatable {
    /// The BSD interface name (for example `en0`, `utun4`, `pdp_ip0`).
    public let interfaceName: String
    /// The numeric address string (IPv4 dotted quad or IPv6, possibly with a
    /// `%zone` suffix as returned by `getnameinfo`).
    public let address: String

    public init(interfaceName: String, address: String) {
        self.interfaceName = interfaceName
        self.address = address
    }
}

/// Pure classification from an interface snapshot to a ``TailscaleStatus``.
public enum TailscaleTailnetDetector {
    /// Classifies an interface-address snapshot.
    ///
    /// - Parameter interfaces: The enumerated interface addresses, or `nil`
    ///   when enumeration itself failed.
    /// - Returns: ``TailscaleStatus/active`` when any tunnel (`utun*`)
    ///   interface holds a Tailscale-range address,
    ///   ``TailscaleStatus/unknown`` for a `nil` snapshot, and
    ///   ``TailscaleStatus/inactiveOrNotInstalled`` otherwise.
    public static func status(forInterfaces interfaces: [NetworkInterfaceAddress]?) -> TailscaleStatus {
        guard let interfaces else { return .unknown }
        let hasTailnetAddress = interfaces.contains { entry in
            isTunnelInterfaceName(entry.interfaceName) && isTailscaleSelfAddress(entry.address)
        }
        return hasTailnetAddress ? .active : .inactiveOrNotInstalled
    }

    /// Whether the interface is a userspace tunnel. Tailscale on Apple
    /// platforms runs as a packet tunnel provider, which always materializes
    /// as a `utun` interface. Restricting to `utun` keeps a carrier handing
    /// out CGNAT addresses on `pdp_ip0` (cellular) from counting as a tailnet.
    static func isTunnelInterfaceName(_ name: String) -> Bool {
        name.hasPrefix("utun")
    }

    /// Whether the numeric address falls in a Tailscale self-address range:
    /// CGNAT `100.64.0.0/10` for IPv4 or ULA `fd7a:115c:a1e0::/48` for IPv6.
    static func isTailscaleSelfAddress(_ address: String) -> Bool {
        // getnameinfo can append a "%zone" suffix on link-scoped IPv6
        // addresses; inet_pton rejects it, so strip before parsing.
        let host = String(address.prefix { $0 != "%" })

        var ipv4 = in_addr()
        if inet_pton(AF_INET, host, &ipv4) == 1 {
            let value = UInt32(bigEndian: ipv4.s_addr)
            // 100.64.0.0/10: top ten bits equal 0b0110_0100_01.
            return value & 0xFFC0_0000 == 0x6440_0000
        }

        var ipv6 = in6_addr()
        if inet_pton(AF_INET6, host, &ipv6) == 1 {
            // fd7a:115c:a1e0::/48: the first six bytes are fixed.
            return withUnsafeBytes(of: &ipv6) { raw in
                raw[0] == 0xFD && raw[1] == 0x7A && raw[2] == 0x11
                    && raw[3] == 0x5C && raw[4] == 0xA1 && raw[5] == 0xE0
            }
        }

        return false
    }
}

/// Source of the current interface-address snapshot. The system
/// implementation walks `getifaddrs`; tests inject fixtures.
public protocol NetworkInterfaceAddressProviding: Sendable {
    /// The current interface addresses, or `nil` when enumeration failed.
    func currentInterfaceAddresses() -> [NetworkInterfaceAddress]?
}

/// The real provider: a single `getifaddrs` walk over IPv4/IPv6 entries.
public struct SystemNetworkInterfaceAddressProvider: NetworkInterfaceAddressProviding {
    public init() {}

    public func currentInterfaceAddresses() -> [NetworkInterfaceAddress]? {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return nil }
        defer { freeifaddrs(head) }

        var results: [NetworkInterfaceAddress] = []
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            guard entry.pointee.ifa_flags & UInt32(IFF_UP) != 0,
                  let addressPointer = entry.pointee.ifa_addr else { continue }
            let family = Int32(addressPointer.pointee.sa_family)
            guard family == AF_INET || family == AF_INET6 else { continue }

            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(
                addressPointer,
                socklen_t(addressPointer.pointee.sa_len),
                &host,
                socklen_t(host.count),
                nil,
                0,
                NI_NUMERICHOST
            ) == 0 else { continue }

            results.append(
                NetworkInterfaceAddress(
                    interfaceName: String(cString: entry.pointee.ifa_name),
                    address: String(cString: host)
                )
            )
        }
        return results
    }
}
