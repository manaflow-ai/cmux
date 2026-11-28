import AppKit

extension CEFTab: BrowserContentVisibilityReporting {
    /// The page window over this tab's content view, if the fork shows one
    /// there: a visible, non-panel child of the host window whose frame
    /// matches the host view's screen rect.
    public var contentVisibility: BrowserContentVisibility {
        guard !isClosed else { return .hidden("closed") }
        guard let window = container.window else { return .hidden("not_in_window") }
        guard host.visibleTab === self, host.hostView.superview === container else { return .hidden("host_elsewhere") }
        guard !host.hostView.isHiddenOrHasHiddenAncestor else { return .hidden("host_hidden") }
        guard browserID != nil else { return .hidden("no_page") }
        let rect = window.convertToScreen(host.hostView.convert(host.hostView.bounds, to: nil))
        let pages = (window.childWindows ?? []).filter { !($0 is NSPanel) && !devToolsContains(window: $0) }
        let placed = pages.filter { abs($0.frame.minX - rect.minX) <= 2 && abs($0.frame.minY - rect.minY) <= 2
            && abs($0.frame.width - rect.width) <= 2 && abs($0.frame.height - rect.height) <= 2 }
        if placed.contains(where: \.isVisible) { return .visible }
        if !placed.isEmpty { return .hidden("page_window_hidden") }
        return .hidden(pages.contains(where: \.isVisible) ? "page_window_misplaced" : "page_window_missing")
    }
}
