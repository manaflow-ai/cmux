public import CmuxNextBrowser
public import CmuxNextDaemon
public import Foundation

extension BrowserHistoryWriter {
    /// The saved web entries a Chromium page restores by address and title when `history` has no engine state it
    /// may use at `url` (``restoreState(_:at:engine:)`` is nil: a page with a password or file field, a state over
    /// the size limit, a form post in its list). Nil when the page shown is not the saved current entry, is a form
    /// result (never sent again without the person) or not a web page, or fewer than two web entries are left.
    /// Local files and other schemes are left out, as the saved-entry replay leaves them (`BrowserRestoredSession`).
    ///
    /// - Parameters:
    ///   - history: The tab's daemon record.
    ///   - url: The page the tab opens at.
    /// - Returns: The entries and the current one's index in them.
    public static func restoreEntries(_ history: FrontendBrowserHistory?, at url: URL?) -> BrowserSavedSession? {
        guard let history, let url, Self.isWebPage(url), restoreState(history, at: url, engine: .cef) == nil,
              history.entries.indices.contains(history.index), history.entries[history.index].url == url.absoluteString,
              history.entries[history.index].formPost != true, let session = session(history) else { return nil }
        let kept = session.entries.indices.filter { $0 == session.current || Self.isWebPage(session.entries[$0].url) }
        guard kept.count > 1, let current = kept.firstIndex(of: session.current) else { return nil }
        return BrowserSavedSession(entries: kept.map { session.entries[$0] }, current: current)
    }

    private static func isWebPage(_ url: URL) -> Bool {
        ["http", "https"].contains(url.scheme?.lowercased() ?? "")
    }
}
