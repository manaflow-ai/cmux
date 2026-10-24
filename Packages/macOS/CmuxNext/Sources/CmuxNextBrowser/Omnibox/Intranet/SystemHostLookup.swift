public import Foundation
public import CmuxNextWakeups

/// ``HostLookup`` over `getaddrinfo`, which uses the Mac's resolver with the
/// DNS search domains a VPN, DHCP or MDM profile set.
///
/// `getaddrinfo` blocks and cannot be cancelled, so it runs on the
/// ``BackgroundWork`` system lane, never on the cooperative pool; the caller
/// stops waiting at its own deadline, and a lookup that has not started by
/// then never runs.
public nonisolated struct SystemHostLookup: HostLookup {
    private let work: BackgroundWork

    /// - Parameter work: the app's blocking-work lanes (AppServices).
    public init(work: BackgroundWork) {
        self.work = work
    }

    public func resolves(_ host: String) async -> Bool {
        // A person waits on it: the bare word they typed opens on Enter only when it resolves.
        let resolved = try? await work.run(.userBlocking, mayBlock: .system) {
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
