public import Foundation

/// Which favicons the app may fetch in its own process. A tab whose store is
/// a remote machine's (a machine store: remote localhost or a Cloud proxied
/// tab) names loopback icons of that machine; the app's fetch would reach
/// this Mac's localhost instead, so it never fetches them (the tab shows a
/// globe). Every other http(s) icon loads as before.
extension URL {
    /// Whether the app may fetch this favicon URL itself. `remoteStore` is
    /// true when the tab's store is a remote machine's.
    public nonisolated func isAppFetchableFavicon(remoteStore: Bool) -> Bool {
        guard remoteStore else { return true }
        guard let host = host(percentEncoded: false)?.lowercased(), !host.isEmpty else { return false }
        let bare = host.hasPrefix("[") && host.hasSuffix("]") ? String(host.dropFirst().dropLast()) : host
        return !BrowserURLResolver.isLoopback(bare)
    }
}
