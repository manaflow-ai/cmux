import CmuxFoundation
import Darwin
import Foundation

/// Confines the blocking system resolver call to a bounded background lane.
struct BrowserPageMetadataDNSWorker: Sendable {
    private let addressPolicy: NetworkAddressPolicy

    init(addressPolicy: NetworkAddressPolicy) {
        self.addressPolicy = addressPolicy
    }

    func resolve(
        host: String,
        completion: @escaping @Sendable ([BrowserPageMetadataResolvedAddress]) -> Void
    ) {
        let addressPolicy = addressPolicy
        DispatchQueue.global(qos: .utility).async { [self] in
            completion(self.resolvedAddresses(for: host, addressPolicy: addressPolicy))
        }
    }

    private func resolvedAddresses(
        for host: String,
        addressPolicy: NetworkAddressPolicy
    ) -> [BrowserPageMetadataResolvedAddress] {
        let normalizedHost = addressPolicy.normalizedHost(host)
        guard addressPolicy.allowsPublicInternetHost(normalizedHost) else { return [] }

        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        hints.ai_protocol = IPPROTO_TCP
        var result: UnsafeMutablePointer<addrinfo>?
        guard Darwin.getaddrinfo(normalizedHost, nil, &hints, &result) == 0,
              let first = result else {
            return []
        }
        defer { Darwin.freeaddrinfo(first) }

        var addresses: [BrowserPageMetadataResolvedAddress] = []
        var cursor: UnsafeMutablePointer<addrinfo>? = first
        while let current = cursor {
            defer { cursor = current.pointee.ai_next }
            guard let socketAddress = current.pointee.ai_addr else { continue }
            switch current.pointee.ai_family {
            case AF_INET:
                let bytes = socketAddress.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                    Array(withUnsafeBytes(of: $0.pointee.sin_addr.s_addr) { $0 })
                }
                guard addressPolicy.allowsPublicIPv4Address(bytes) else { return [] }
                addresses.append(BrowserPageMetadataResolvedAddress(family: .ipv4, bytes: bytes))
            case AF_INET6:
                let bytes = socketAddress.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) {
                    Array(withUnsafeBytes(of: $0.pointee.sin6_addr) { $0 })
                }
                guard addressPolicy.allowsPublicIPv6Address(bytes) else { return [] }
                addresses.append(BrowserPageMetadataResolvedAddress(family: .ipv6, bytes: bytes))
            default:
                return []
            }
        }
        var seen: Set<BrowserPageMetadataResolvedAddress> = []
        return addresses.filter { seen.insert($0).inserted }
    }
}
