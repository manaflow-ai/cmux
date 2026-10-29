public import Foundation

/// ``HostLookup`` over `getaddrinfo`, which uses the Mac's resolver with the
/// DNS search domains a VPN, DHCP or MDM profile set.
public nonisolated struct SystemHostLookup: HostLookup {
    public init() {}

    public func resolves(_ host: String) async -> Bool {
        // getaddrinfo blocks and cannot be cancelled: it runs off the
        // caller, which stops waiting at its own deadline.
        await Task.detached(priority: .userInitiated) {
            var hints = addrinfo()
            hints.ai_socktype = SOCK_STREAM
            var result: UnsafeMutablePointer<addrinfo>?
            let status = getaddrinfo(host, nil, &hints, &result)
            if let result { freeaddrinfo(result) }
            return status == 0
        }.value
    }
}
