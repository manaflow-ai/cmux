public import Foundation

/// A local web page a turn started or mentioned (a dev server on localhost):
/// the page's preview card shows it live in a frame and opens it in a cmux
/// browser tab. Only http(s) pages on this machine's loopback qualify, so
/// neither the frame nor the open request reaches past the machine.
public nonisolated enum AgentPanePreview {
    /// `url` when it is an http(s) page on the loopback interface, else nil.
    public static func loopback(_ url: URL?) -> URL? {
        guard let url, let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              url.user == nil, url.password == nil,
              let host = url.host(percentEncoded: false)?.lowercased(), loopbackHosts.contains(host) else { return nil }
        return url
    }

    /// The hosts the page's CSP lets a frame load (`frame-src`); CSP cannot
    /// name an IPv6 literal, so `[::1]` is left out here too.
    static let loopbackHosts: Set<String> = ["localhost", "127.0.0.1"]
}
