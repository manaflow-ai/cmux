import Foundation

/// Validates browser origins before an unauthenticated WebSocket upgrade.
nonisolated struct WebClientBridgeOriginPolicy: Sendable {
    let bindAddress: WebClientBridgeBindAddress

    /// Allows local development pages for every bind. A Tailscale bind also
    /// allows a page served from that exact CGNAT address or a private
    /// HTTPS `*.ts.net` origin used by `tailscale serve`.
    func allows(originHeader: String?) -> Bool {
        guard let originHeader,
              let url = URL(string: originHeader),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.user == nil,
              url.password == nil,
              let rawHost = url.host else {
            return false
        }
        let host = rawHost.lowercased()
        if case let .success(address) = WebClientBridgeBindAddress.validate(host),
           address.kind == .loopback {
            return true
        }
        guard bindAddress.kind == .tailscale else { return false }
        if host == bindAddress.host.lowercased() { return true }
        return scheme == "https" && host.hasSuffix(".ts.net")
    }
}
