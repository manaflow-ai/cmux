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
        guard let mask = CmxIrohIPLiteral(value, family: family) else {
            throw CmxIrohLANDiscoveryError.invalidInterface
        }
        return mask.bytes
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
        // SAFETY: getifaddrs stores the head of a list it allocates in `first`. The
        // defer below frees it once, and the loop copies every field it reads into
        // Swift values, so no pointer into the list outlives this function.
        guard unsafe getifaddrs(&first) == 0 else {
            throw CmxIrohLANDiscoveryError.invalidInterface
        }
        // SAFETY: frees the list getifaddrs returned, exactly once.
        defer { unsafe freeifaddrs(first) }

        var result: [CmxIrohLANInterfaceAddress] = []
        // SAFETY: the walk starts at the live list's head.
        var cursor = unsafe first
        // SAFETY: `cursor` is a node of the live list or nil, which ends the walk.
        while let current = unsafe cursor?.pointee {
            // SAFETY: ifa_next is the next node of the live list or nil.
            cursor = unsafe current.ifa_next
            let flags = Int32(bitPattern: current.ifa_flags)
            guard flags & IFF_UP != 0,
                  flags & IFF_RUNNING != 0,
                  flags & IFF_MULTICAST != 0,
                  flags & IFF_LOOPBACK == 0,
                  flags & IFF_POINTOPOINT == 0 else { continue }
            // SAFETY: ifa_addr and ifa_netmask are nil or sockaddrs inside the live list;
            // they are only read below, before the defer frees the list.
            guard let addressPointer = unsafe current.ifa_addr,
                  let maskPointer = unsafe current.ifa_netmask else { continue }
            // SAFETY: addressPointer is a live sockaddr (see above); sa_family is its first field.
            let family = unsafe Int32(clamping: addressPointer.pointee.sa_family)
            guard family == AF_INET || family == AF_INET6 else { continue }
            // SAFETY: ifa_name is the node's NUL-terminated name; String(cString:) copies it.
            let name = unsafe String(cString: current.ifa_name)
            guard Self.isEligibleInterfaceName(name) else { continue }
            // SAFETY: if_nametoindex reads the NUL-terminated copy of `name` made for this call.
            let index = unsafe if_nametoindex(name)
            // SAFETY: both pointers are live sockaddrs (see above); numericAddress copies
            // the text it formats before returning.
            guard index != 0,
                  let address = unsafe Self.numericAddress(addressPointer),
                  let mask = unsafe Self.numericAddress(maskPointer),
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

    /// The numeric host text of a sockaddr from getifaddrs; the caller keeps its list alive.
    private static func numericAddress(_ pointer: UnsafePointer<sockaddr>) -> String? {
        var host = [CChar](repeating: 0, count: Int(clamping: NI_MAXHOST))
        // SAFETY: `pointer` is a live sockaddr whose sa_len bytes are readable (the caller
        // holds the getifaddrs list); getnameinfo writes at most host.count bytes, the
        // size passed, NUL included, and nothing for the absent service buffer.
        let result = unsafe getnameinfo(
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
