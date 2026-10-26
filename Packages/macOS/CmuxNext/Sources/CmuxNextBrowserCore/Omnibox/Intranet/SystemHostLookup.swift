public import CmuxNextCompat
public import Foundation

/// ``HostLookup`` over `getaddrinfo`, which uses the Mac's resolver with the
/// DNS search domains a VPN, DHCP or MDM profile set.
public nonisolated struct SystemHostLookup: HostLookup {
    /// The app's blocking-work lanes: the lookup runs on the system lane, several at once (Chrome's
    /// `kDefaultMaxSystemTasks`, net/dns/host_resolver_manager.cc), never on the cooperative pool.
    private let runner: any MayBlockRunner

    public init(runner: any MayBlockRunner) {
        self.runner = runner
    }

    /// Whether `host` resolves; false when it does not or the lookup was refused (quit began).
    public func resolves(_ host: String) async -> Bool {
        // getaddrinfo blocks and cannot be cancelled: the caller stops waiting at its own deadline.
        let resolved = try? await runner.runSystem(.userVisible) {
            var hints = addrinfo()
            hints.ai_socktype = SOCK_STREAM
            var result: UnsafeMutablePointer<addrinfo>?
            let status = getaddrinfo(host, nil, &hints, &result)
            if let result { freeaddrinfo(result) }
            return status == 0
        }
        return resolved ?? false
    }
}
