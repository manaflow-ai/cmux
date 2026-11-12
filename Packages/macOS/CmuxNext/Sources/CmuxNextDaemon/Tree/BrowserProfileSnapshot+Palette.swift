import Foundation

extension BrowserProfileSnapshot {
    /// The insertion index `move-browser-profile` takes for a 1-based `position` among `count` profiles, the
    /// moved one at `old` (0-based): the daemon counts it before the profile leaves its place
    /// (`insertion_final_index`), so a place past `old` is one more, and the last place is `count`.
    public static func moveIndex(position: Int, from old: Int, count: Int) -> Int {
        let place = min(max(position - 1, 0), max(count - 1, 0))
        return place > old ? place + 1 : place
    }
}

extension BrowserProfileSnapshot.Proxy {
    /// The proxy a palette's answers name, or nil when a part is missing or out of range (the scheme, an empty
    /// host, the port); the daemon still checks the host as it does the CLI's.
    public static func palette(scheme: String?, host: String?, port: Int?) -> Self? {
        let host = host?.trimmingCharacters(in: .whitespaces) ?? ""
        guard let scheme, ["http", "https", "socks5"].contains(scheme), !host.isEmpty, let port, (1...65_535).contains(port) else { return nil }
        return Self(scheme: scheme, host: host, port: port)
    }
}
