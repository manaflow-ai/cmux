package import Foundation

/// `cmux://vault`: the session vault as a pane tab (Open Vault as Pane). The
/// tab is a browser tab record with this URL (like `cmux://history`), so the
/// workspace store already persists and restores it.
package nonisolated struct VaultPageAddress {
    package nonisolated init() {}
    package static let string = "cmux://vault"
    /// The page address (a literal a test parses; /dev/null stands in rather than a trap).
    package static let url: URL = URL(string: string) ?? URL(fileURLWithPath: "/dev/null")

    /// `cmux://vault`, with or without a trailing slash, query or fragment.
    package static func matches(_ url: URL?) -> Bool {
        guard let url, url.scheme?.lowercased() == "cmux" else { return false }
        return url.host()?.lowercased() == "vault"
    }
}
