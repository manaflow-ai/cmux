import Foundation

/// The real ``NetworkInterfaceAddressProviding``: a single `getifaddrs` walk
/// over the up IPv4/IPv6 interface entries.
public struct SystemNetworkInterfaceAddressProvider: NetworkInterfaceAddressProviding {
    /// Creates a system-backed provider.
    public init() {}

    /// Enumerates the device's current interface addresses.
    ///
    /// - Returns: One entry per up IPv4/IPv6 interface address, or `nil` when
    ///   the `getifaddrs` walk itself failed.
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
