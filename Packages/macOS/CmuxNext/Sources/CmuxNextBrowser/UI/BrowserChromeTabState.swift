import AppKit

/// What one browser tab shows in its pane's chrome, kept with the tab while another tab of the pane shows
/// (Chrome's model: one `BrowserView` and `ToolbarView` per window, and per tab only the state the toolbar
/// shows for it, `OmniboxView::SaveStateToTab`, `FindBarController::ChangeWebContents`). The pane's chrome
/// binds to the selected tab's state (`BrowserChromeView.bind(_:state:)`); a new tab in a pane that has a
/// chrome builds no chrome view.
@MainActor
public final class BrowserChromeTabState {
    public init() {}
}

extension BrowserChromeView {
    /// Shows `tab` with its own toolbar state `state`: a tab switch in a pane that shares this chrome.
    /// The same state with another page is that tab's page replaced (a woken hibernated page).
    public func bind(_ tab: any BrowserTab, state: BrowserChromeTabState) {
        self.tab = tab
    }
}
