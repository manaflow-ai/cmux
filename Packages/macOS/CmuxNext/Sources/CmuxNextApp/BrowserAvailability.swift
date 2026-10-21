import Foundation

/// Whether a browser tab may open for an address while `browser.enabled` says whether the cmux
/// browser is on (classic's Disable cmux Browser, e46e80b424f). Off, cmux's own pages
/// (`cmux://history`, `cmux://agent-activity`, `cmux-page://...`) still open as tabs; a web page,
/// a file, a blank New Tab page or another machine's browser does not.
nonisolated struct BrowserAvailability: Equatable, Sendable {
    /// `browser.enabled`.
    let enabled: Bool

    /// True when a tab for `address` may open.
    func allows(_ address: String?) -> Bool {
        enabled || address.flatMap(URL.init(string:)).map(Self.isCmuxPage) == true
    }

    /// A page cmux draws itself, not a web page: `cmux://` (except a machine's browser record) and `cmux-page://`.
    static func isCmuxPage(_ url: URL) -> Bool {
        switch url.scheme?.lowercased() {
        case "cmux-page": return true
        case "cmux": return !MachineBrowserRecord.matches(url)
        default: return false
        }
    }
}
