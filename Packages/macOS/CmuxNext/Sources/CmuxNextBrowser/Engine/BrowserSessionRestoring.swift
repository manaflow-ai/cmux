import Foundation

/// A tab that can take back the session history saved before a relaunch
/// (Chromium; plans/cmux-next/browser.md, "Session history across relaunch").
public protocol BrowserSessionRestoring: AnyObject {
    /// `entries[current]` is the page the tab loads; the others become its
    /// Back and Forward entries, and the page scrolls back to its position.
    func restoreSession(_ entries: [BrowserSavedEntry], current: Int)
    /// How far the shown page is scrolled; nil when it cannot say.
    func currentScrollY() async -> Double?
    /// The tab's back/forward entries as they are saved for a relaunch,
    /// with the scroll positions the tab knows; `measuringScroll` also asks
    /// the shown page. Nil before the tab shows a page.
    func savedSession(measuringScroll: Bool) async -> BrowserSavedSession?
}

/// A tab's back/forward entries, oldest first, and the one it shows.
public nonisolated struct BrowserSavedSession: Hashable, Sendable {
    public var entries: [BrowserSavedEntry]
    public var current: Int

    public init(entries: [BrowserSavedEntry], current: Int) {
        self.entries = entries
        self.current = current
    }
}
