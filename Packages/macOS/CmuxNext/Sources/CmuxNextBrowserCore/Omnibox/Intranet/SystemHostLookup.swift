public import CmuxNextCompat
public import Foundation

/// ``HostLookup`` over `getaddrinfo`, which uses the Mac's resolver with the
/// DNS search domains a VPN, DHCP or MDM profile set.
///
/// The lookup blocks and cannot be cancelled, so it runs on the system lane's
/// host-resolution slots (``MayBlockRunner/runHostResolution(_:shutdown:site:_:)``),
/// never on the cooperative pool; the caller stops waiting at its own deadline.
public nonisolated struct SystemHostLookup: HostLookup {
    private let runner: any MayBlockRunner

    /// - Parameter runner: The app's lanes (BackgroundWork).
    public init(runner: any MayBlockRunner) {
        self.runner = runner
    }

    /// Whether `host` resolves; false when it does not or the lookup was refused (quit began).
    public func resolves(_ host: String) async -> Bool {
        // A person is typing the word; the omnibar shows the answer.
        let status = try? await runner.runHostResolution(.userBlocking) { () -> Int32 in
            var hints = addrinfo()
            hints.ai_socktype = SOCK_STREAM
            var result: UnsafeMutablePointer<addrinfo>?
            let status = blockingGetaddrinfo(host, nil, &hints, &result)
            if let result { freeaddrinfo(result) }
            return status
        }
        return status == 0
    }
}
