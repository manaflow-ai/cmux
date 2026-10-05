import AppKit

/// Internal pages: cmux's own surfaces (Settings, Debug Settings, the App
/// Store) shown as tabs in a pane instead of windows of their own.
///
/// One mechanism for every page (plans/cmux-next/COORDINATION.md, lane 20):
/// - a session-local tab kind, ids `local-page:<page>:<uuid>`
///   (``LocalPageTab``), kept by ``InternalPageTabStore`` like agent tabs
///   (not restored after relaunch);
/// - a page registers one ``InternalPageProvider`` (`services.pages.register`);
/// - its catalog show action (`openSettings`, `openDebugSettings`,
///   `appStore.show`) calls `services.pages.show(<page>)`, which selects the
///   page's tab in the active window or opens one after the focused pane's
///   selected tab. One tab per page per window.
nonisolated struct InternalPageID: RawRepresentable, Hashable, Sendable {
    let rawValue: String

    init(rawValue: String) { self.rawValue = rawValue }

    static let settings = InternalPageID(rawValue: "settings")
    static let debugSettings = InternalPageID(rawValue: "debug-settings")
}

/// Ids of internal page tabs.
nonisolated enum LocalPageTab {
    static let prefix = "local-page:"

    static func makeKey(_ page: InternalPageID) -> String {
        prefix + page.rawValue + ":" + UUID().uuidString.lowercased()
    }

    /// The page a tab id shows, or nil for another kind of tab.
    static func page(of key: String) -> InternalPageID? {
        guard key.hasPrefix(prefix) else { return nil }
        let rest = key.dropFirst(prefix.count)
        guard let colon = rest.lastIndex(of: ":"), colon > rest.startIndex else { return nil }
        return InternalPageID(rawValue: String(rest[..<colon]))
    }
}

/// What a page tells the shell. The provider is the page's owner: it keeps
/// the page model (one per app is usual) and makes one view per tab.
@MainActor
protocol InternalPageProvider: AnyObject {
    var page: InternalPageID { get }
    /// The tab title (localized).
    var title: String { get }
    /// SF Symbol of the tab.
    var symbol: String { get }
    /// A new view for the tab `key` (called once per tab, on first show).
    /// `window` is the main window the tab opens in, for its theme scope.
    func makeView(for key: String, in window: WindowController?) -> NSView
    /// The tab `key` closed: its view is gone.
    func tabClosed(_ key: String)
    /// The title of tab `key`, for a page whose tabs show different things
    /// (a diff tab names its folder). Default: ``title``.
    func title(for key: String) -> String
}

extension InternalPageProvider {
    func tabClosed(_ key: String) {}
    func title(for key: String) -> String { title }
}
