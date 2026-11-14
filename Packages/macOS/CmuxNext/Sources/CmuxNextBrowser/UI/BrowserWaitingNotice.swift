/// A tab notice that says something waits on a condition ("Chromium is downloading, so this tab uses
/// WebKit"): shown on one tab, and taken away when the condition ends (``end()``), unless the tab's
/// notice says something else by then. Before, the notice stayed after Chromium was ready.
public final class BrowserWaitingNotice {
    private weak var tab: BrowserChromeTabState?
    private var text: String?

    public init() {}

    /// Shows `text` on `tab` (now, or when the tab next shows) until ``end()``.
    public func show(_ text: String, on tab: BrowserChromeTabState) {
        tab.showNotice(text)
        self.tab = tab
        self.text = text
    }

    /// The condition ended: the notice goes if it still says what ``show(_:on:)`` showed.
    public func end() {
        if let text { tab?.hideNotice(saying: text) }
        tab = nil
        text = nil
    }
}
