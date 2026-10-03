import Foundation

extension URL {
    /// A local web page a turn started or mentioned (a dev server on
    /// localhost), which the page's preview card shows live in a frame and
    /// opens in a cmux browser tab: an http(s) page on the loopback hosts the
    /// page's CSP `frame-src` names, with no user info. CSP cannot name an
    /// IPv6 literal, so `[::1]` does not qualify; neither the frame nor the
    /// open request reaches past the machine.
    nonisolated var isAgentPanePreview: Bool {
        guard let scheme = scheme?.lowercased(), scheme == "http" || scheme == "https",
              user == nil, password == nil,
              let host = host(percentEncoded: false)?.lowercased() else { return false }
        return host == "localhost" || host == "127.0.0.1"
    }
}
