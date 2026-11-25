import AppKit
import CmuxNextIcons
import CmuxNextPages

typealias InternalPageID = CmuxNextPages.InternalPageID
typealias LocalPageTab = CmuxNextPages.LocalPageTab

/// What a page tells the shell. The provider is the page's owner: it keeps
/// the page model (one per app is usual) and makes one view per tab.
@MainActor
protocol InternalPageProvider: AnyObject {
    var page: InternalPageID { get }
    /// The tab title (localized).
    var title: String { get }
    /// SF Symbol of the tab, drawn when `icon` is nil.
    var symbol: String { get }
    /// The tab's cmux icon. Default: nil.
    var icon: IconName? { get }
    /// A new view for the tab `key` (called once per tab, on first show).
    /// `window` is the main window the tab opens in, for its theme scope.
    func makeView(for key: String, in window: WindowController?) -> NSView
    /// The tab `key` closed: its view is gone.
    func tabClosed(_ key: String)
    /// The title of tab `key`, for a page whose tabs show different things
    /// (a diff tab names its folder). Default: ``title``.
    func title(for key: String) -> String
    /// The page history of tab `key` (``PageHistory``), for a page with
    /// sub-views. Default: none.
    func history(for key: String) -> (any PageHistory)?
    /// What tab `key` shows (a viewer's file or folder), kept as its store
    /// tab's route (`page-tab-route-v1`) so a reopened or relaunched tab
    /// shows it again (reopen-closed.md 3.0). Default: nil.
    func route(for key: String) -> String?
    /// A store tab came back with `route` (Reopen Closed, relaunch): tab
    /// `key` shows it, set up before its first view. The route comes from the
    /// daemon, so a provider treats it like an open it did not choose (an
    /// agent's open). Default: nothing.
    func restore(_ route: String, for key: String)
    /// The title of a store tab known only by its `route` (restored, not yet
    /// shown, so it has no key): nil uses ``title``. Default: nil.
    func title(forRoute route: String) -> String?
    /// A native bar shown above tab `key`'s view (the Markdown omnibar),
    /// asked once right after ``makeView(for:in:)``. Default: none.
    func makeTopBar(for key: String) -> NSView?
}

extension InternalPageProvider {
    var icon: IconName? { nil }
    func tabClosed(_ key: String) {}
    func title(for key: String) -> String { title }
    func history(for key: String) -> (any PageHistory)? { nil }
    func route(for key: String) -> String? { nil }
    func restore(_ route: String, for key: String) {}
    func title(forRoute route: String) -> String? { nil }
    func makeTopBar(for key: String) -> NSView? { nil }
}
