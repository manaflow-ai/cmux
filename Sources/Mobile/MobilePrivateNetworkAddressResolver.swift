import CMUXMobileCore
import Darwin
import Foundation

/// Discovers safe private-network address suggestions from active interfaces.
// Every mutation of the TTL cache is serialized by `cacheLock`.
final class MobilePrivateNetworkAddressResolver: @unchecked Sendable {
    static let shared = MobilePrivateNetworkAddressResolver()

    private static let cacheTTL: TimeInterval = 30

    // The synchronous interface walk is callable from non-async status paths;
    // this lock protects only its small TTL snapshot and never wraps I/O.
    private let cacheLock = NSLock()
    private var cachedAddresses: [CmxPrivateNetworkAddress] = []
    private var cachedAt: Date?
    /// Prevents a scan started on an old network from repopulating the cache.
    private var cacheGeneration = 0

    /// Returns a stable snapshot, refreshing it after the 30-second TTL.
    func addresses(
        now: Date = Date(),
        scan: () -> [CmxPrivateNetworkAddress] = {
            MobilePrivateNetworkAddressResolver.scanInterfaces()
        }
    ) -> [CmxPrivateNetworkAddress] {
        cacheLock.lock()
        if let cachedAt,
           now.timeIntervalSince(cachedAt) >= 0,
           now.timeIntervalSince(cachedAt) <= Self.cacheTTL {
            let result = cachedAddresses
            cacheLock.unlock()
            return result
        }
        let generation = cacheGeneration
        cacheLock.unlock()

        let resolved = CmxPrivateNetworkAddress.sorted(scan())
        cacheLock.lock()
        guard generation == cacheGeneration else {
            cacheLock.unlock()
            return resolved
        }
        cachedAddresses = resolved
        cachedAt = now
        cacheLock.unlock()
        return resolved
    }

    /// Drops the cached interface snapshot after a network-path change.
    func invalidateCache() {
        cacheLock.lock()
        cachedAddresses = []
        cachedAt = nil
        cacheGeneration &+= 1
        cacheLock.unlock()
    }

    private static func scanInterfaces() -> [CmxPrivateNetworkAddress] {
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaces) == 0, let firstInterface = interfaces else {
            return []
        }
        defer { freeifaddrs(interfaces) }

        var candidates: [CmxPrivateNetworkAddress] = []
        var pointer: UnsafeMutablePointer<ifaddrs>? = firstInterface
        while let current = pointer {
            defer { pointer = current.pointee.ifa_next }

            let flags = Int32(current.pointee.ifa_flags)
            guard flags & IFF_UP != 0,
                  flags & IFF_RUNNING != 0,
                  flags & IFF_LOOPBACK == 0,
                  let name = current.pointee.ifa_name,
                  let socketAddress = current.pointee.ifa_addr,
                  let numericHost = numericHost(for: socketAddress),
                  let candidate = CmxPrivateNetworkAddress.classify(
                      interfaceName: String(cString: name),
                      address: numericHost
                  ) else {
                continue
            }
            candidates.append(candidate)
        }
        return candidates
    }

    private static func numericHost(
        for address: UnsafeMutablePointer<sockaddr>
    ) -> String? {
        switch Int32(address.pointee.sa_family) {
        case AF_INET, AF_INET6:
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let result = getnameinfo(
                address,
                socklen_t(address.pointee.sa_len),
                &host,
                socklen_t(host.count),
                nil,
                0,
                NI_NUMERICHOST
            )
            return result == 0 ? String(cString: host) : nil
        default:
            return nil
        }
    }
}
