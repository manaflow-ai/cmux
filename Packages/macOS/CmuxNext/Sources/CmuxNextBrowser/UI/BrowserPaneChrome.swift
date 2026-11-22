public import AppKit

/// One browser chrome per pane (#32909 step B, Chrome's model: one `BrowserView` and toolbar per window, the tab's
/// contents swapped in). The pane's browser tabs share it: a new browser tab in a pane that has one builds no
/// chrome, and a switch between two of them rebinds it (`BrowserChromeView.bind(_:state:)`) instead of showing
/// another chrome. A tab moved to another pane binds that pane's chrome there.
@MainActor
public final class BrowserPaneChrome {
    public private(set) var chrome: BrowserChromeView?
    /// The page the chrome shows while the pane shows `content` (nil when that is not this chrome): a replaced page
    /// (a woken hibernated one) is new content under the same chrome, a change under a hidden chrome is none.
    public func page(shown content: NSView?) -> NSView? {
        guard let chrome, content === chrome else { return nil }
        return chrome.tab.contentView
    }

    public init() {}

    /// The pane's chrome, showing `tab` with its `state`: made with the pane's first browser tab, rebound for every later one.
    @discardableResult
    public func bind(_ tab: any BrowserTab, state: BrowserChromeTabState) -> BrowserChromeView {
        if let chrome {
            chrome.bind(tab, state: state)
            return chrome
        }
        let chrome = BrowserChromeView(tab: tab, suggestionEngine: state.suggestionEngine ?? OmniboxSuggestionEngine())
        // Shortcuts route through the action registry (browser* actions).
        chrome.handlesDefaultShortcuts = false
        chrome.bind(tab, state: state)
        self.chrome = chrome
        return chrome
    }

    /// The pane goes: the chrome's popup panels (Page Info, the Extensions bubble) close for good.
    public func drop() {
        chrome?.closePopupPanels()
        chrome?.removeFromSuperview()
        chrome = nil
    }
}
