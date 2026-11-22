import CmuxNextApps

/// A page's own Back and Forward (plans/cmux-next/history.md 4.2b): the
/// sub-views one tab or top page moved through, like a browser tab's
/// history. Go Back and Go Forward (titlebar arrows, Cmd-[ / Cmd-], mouse
/// buttons 4 and 5, a swipe) walk the shown page's history first and the
/// location trail after it (``LocationTrailService/navigate(_:)``).
@MainActor
protocol PageHistory: AnyObject {
    var canGoBack: Bool { get }
    var canGoForward: Bool { get }
    /// False when there is nothing older.
    @discardableResult func goBack() -> Bool
    /// False when there is nothing newer.
    @discardableResult func goForward() -> Bool
}

/// The App Store: Discover, Installed, a search and each opened listing.
extension AppStoreModel: PageHistory {}
