import Darwin
import Foundation

/// One eligible local-interface address and its subnet mask.
public struct CmxIrohLANInterfaceAddress: Equatable, Hashable, Sendable {
    public let interfaceIndex: UInt32
    public let ipAddress: String
    public let family: CmxIrohLANSocketAddress.Family

    let addressBytes: [UInt8]
    let netmaskBytes: [UInt8]

    public init(
        interfaceIndex: UInt32,
        ipAddress: String,
        netmask: String
    ) throws {
        guard interfaceIndex != 0 else { throw CmxIrohLANDiscoveryError.invalidInterface }
        let address = try CmxIrohLANSocketAddress(
            CmxIrohLANSocketAddress.canonicalValue(ipAddress: ipAddress, port: 1)
        )
        let mask = try Self.parseMask(netmask, family: address.family)
        guard mask.count == address.addressBytes.count,
              Self.isContiguousMask(mask) else {
            throw CmxIrohLANDiscoveryError.invalidInterface
        }
        self.interfaceIndex = interfaceIndex
        self.ipAddress = address.ipAddress
        family = address.family
        addressBytes = address.addressBytes
        netmaskBytes = mask
    }

    /// Whether a remote address is on-link for this exact DNS-SD interface.
    public func contains(_ address: CmxIrohLANSocketAddress) -> Bool {
        guard address.family == family,
              address.addressBytes.count == addressBytes.count else { return false }
        return zip(address.addressBytes, zip(addressBytes, netmaskBytes)).allSatisfy {
            ($0.0 & $0.1.1) == ($0.1.0 & $0.1.1)
        }
    }

    private static func parseMask(
        _ value: String,
        family: CmxIrohLANSocketAddress.Family
    ) throws -> [UInt8] {
        switch family {
        case .ipv4:
            var address = in_addr()
            guard value.withCString({ inet_pton(AF_INET, $0, &address) }) == 1 else {
                throw CmxIrohLANDiscoveryError.invalidInterface
            }
            return withUnsafeBytes(of: &address) { Array($0) }
        case .ipv6:
            var address = in6_addr()
            guard value.withCString({ inet_pton(AF_INET6, $0, &address) }) == 1 else {
                throw CmxIrohLANDiscoveryError.invalidInterface
            }
            return withUnsafeBytes(of: &address) { Array($0) }
        }
    }

    private static func isContiguousMask(_ bytes: [UInt8]) -> Bool {
        var sawZero = false
        for byte in bytes {
            for bit in (0 ..< 8).reversed() {
                let set = byte & (1 << bit) != 0
                if sawZero && set { return false }
                if !set { sawZero = true }
            }
        }
        return bytes.contains(where: { $0 != 0 })
    }
}

/// Supplies current eligible multicast-capable LAN interfaces.
public protocol CmxIrohLANInterfaceSnapshotProviding: Sendable {
    func interfaceAddresses() throws -> [CmxIrohLANInterfaceAddress]
}

/// Reads user-facing Wi-Fi, Ethernet, VLAN, and bonded-link interfaces without
/// exposing their names. Generic VPN and VM reachability stays in explicit
/// private-network Iroh hints and is never advertised through Bonjour.
public struct CmxIrohSystemLANInterfaceSnapshotProvider: CmxIrohLANInterfaceSnapshotProviding {
    public init() {}

    public func interfaceAddresses() throws -> [CmxIrohLANInterfaceAddress] {
        var first: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&first) == 0 else {
            throw CmxIrohLANDiscoveryError.invalidInterface
        }
        defer { freeifaddrs(first) }

        var result: [CmxIrohLANInterfaceAddress] = []
        var cursor = first
        while let current = cursor?.pointee {
            defer { cursor = current.ifa_next }
            let flags = Int32(current.ifa_flags)
            guard flags & IFF_UP != 0,
                  flags & IFF_RUNNING != 0,
                  flags & IFF_MULTICAST != 0,
                  flags & IFF_LOOPBACK == 0,
                  flags & IFF_POINTOPOINT == 0,
                  let addressPointer = current.ifa_addr,
                  let maskPointer = current.ifa_netmask else { continue }
            let family = Int32(addressPointer.pointee.sa_family)
            guard family == AF_INET || family == AF_INET6 else { continue }
            let name = String(cString: current.ifa_name)
            guard Self.isEligibleInterfaceName(name) else { continue }
            let index = if_nametoindex(name)
            guard index != 0,
                  let address = Self.numericAddress(addressPointer),
                  let mask = Self.numericAddress(maskPointer),
                  let value = try? CmxIrohLANInterfaceAddress(
                      interfaceIndex: index,
                      ipAddress: address,
                      netmask: mask
                  ) else { continue }
            result.append(value)
        }
        return Array(Set(result)).sorted {
            if $0.interfaceIndex != $1.interfaceIndex {
                return $0.interfaceIndex < $1.interfaceIndex
            }
            return $0.ipAddress < $1.ipAddress
        }
    }

    static func isEligibleInterfaceName(_ value: String) -> Bool {
        // Darwin assigns enN to user Wi-Fi/Ethernet hardware, vlanN to
        // configured 802.1Q links, and bondN to configured link aggregates.
        // A narrow allowlist avoids publishing into multicast-capable VM,
        // container, tunnel, peer-to-peer, and ambiguous bridge interfaces.
        for prefix in ["en", "vlan", "bond"] where value.hasPrefix(prefix) {
            let suffix = value.dropFirst(prefix.count)
            if !suffix.isEmpty,
               suffix.utf8.allSatisfy({ (48 ... 57).contains($0) }) { return true }
        }
        return false
    }

    private static func numericAddress(_ pointer: UnsafePointer<sockaddr>) -> String? {
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let result = getnameinfo(
            pointer,
            socklen_t(pointer.pointee.sa_len),
            &host,
            socklen_t(host.count),
            nil,
            0,
            NI_NUMERICHOST
        )
        guard result == 0 else { return nil }
        let value = String(
            decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) },
            as: UTF8.self
        )
        return value.split(separator: "%", maxSplits: 1).first.map(String.init)
    }
}
