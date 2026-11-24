import AppKit

/// A new tab of the pane whose page comes a frame later (the stand-in of `PaneBrowserTabOpener.openStandIn`, whose
/// page and chrome binding follow the key's frame, PL-cef-tab): the pane keeps showing its one chrome, its toolbar
/// row in place, with an empty address and no page, instead of showing no content for that frame. Chrome's model: the
/// toolbar is the window's and stays while a new tab's contents wait for their page. Before (in-tree sweep D8), ten
/// Cmd-Shift-L at 80 ms showed the pane bare, toolbar row gone, for 28-34 frames: each stand-in's frame showed no content.
extension BrowserChromeView {
    /// The tab shown now leaves for a new tab whose page has not come: its toolbar state and page are kept as in a tab
    /// switch (`bind(_:state:)`), its page hidden in the page area, and the address bar shows an empty address. The
    /// toolbar's buttons stay as they are (hiding them would lay the row out again for one frame); until the next
    /// ``bind(_:state:)`` they act on the hidden tab. That bind shows the new tab (or the same tab again) as usual.
    /// Nothing happens with no bound tab.
    public func awaitNewTab() {
        guard let state = boundState, !isAwaitingTab else { return }
        BrowserChromeTabSwitch(chrome: self).save(into: state)
        BrowserPageArea(container: contentContainer).leave(tab.contentView, parks: true)
        addressBar.restore(OmnibarState())
        isAwaitingTab = true
    }
}
