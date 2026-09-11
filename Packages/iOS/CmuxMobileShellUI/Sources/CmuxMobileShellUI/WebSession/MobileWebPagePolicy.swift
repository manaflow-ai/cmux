#if os(iOS)
import Foundation

/// Whether an in-app cmux webpage may load `url`: https on an allowlisted
/// cmux-owned host, or plain http only for a loopback development host that
/// is itself allowlisted (how local dev servers are addressed). One policy
/// covers the initial page and every subsequent navigation, so an https page
/// cannot downgrade to plaintext through a link or redirect. The web app
/// session broker applies the same policy before any credential exchange,
/// so auth material can only ever flow to a destination this would allow.
func mobileWebPageURLAllowed(_ url: URL, allowedHosts: Set<String>) -> Bool {
    guard let host = url.host?.lowercased(), allowedHosts.contains(host) else { return false }
    switch url.scheme?.lowercased() {
    case "https":
        return true
    case "http":
        return host == "localhost" || host == "127.0.0.1"
    default:
        return false
    }
}

/// The hosts cmux-owned in-app webpages may load: the production web hosts
/// plus the build's configured API host, so dev and staging builds render
/// pages against their own web app. One derivation shared by the What's New
/// allowlist and the web app session broker, so the navigation policy and
/// the credential policy can never disagree about what "cmux-owned" means.
enum MobileWebPageHosts {
    /// cmux-owned production web hosts.
    static let cmuxOwned: Set<String> = ["cmux.com", "www.cmux.com"]

    /// The full allowlist for a build configured with `apiBaseURL`.
    static func allowedHosts(apiBaseURL: String?) -> Set<String> {
        var hosts = cmuxOwned
        if let apiBaseURL,
           !apiBaseURL.isEmpty,
           let host = URL(string: apiBaseURL)?.host?.lowercased() {
            hosts.insert(host)
        }
        return hosts
    }
}
#endif
