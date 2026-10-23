public import AppKit

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
        let placed = pages.filter { Self.frame($0.frame, isPlacedAt: rect) }
        if placed.contains(where: \.isVisible) { return .visible }
        if !placed.isEmpty { return .hidden("page_window_hidden") }
        return .hidden(pages.contains(where: \.isVisible) ? "page_window_misplaced" : "page_window_missing")
    }

    /// Whether `window` is the page window over this tab's content view: a child of the
    /// container's window at the host view's screen rect, as ``contentVisibility`` finds it.
    ///
    /// - Parameter window: A window to test, such as the key window a key-down goes to.
    /// - Returns: Whether Chromium's page window for this tab is `window`, so its keys reach the page.
    public func isPageWindow(_ window: NSWindow) -> Bool {
        guard !isClosed, let owner = container.window, window.parent === owner,
              host.visibleTab === self, host.hostView.superview === container else { return false }
        return Self.frame(window.frame, isPlacedAt: owner.convertToScreen(host.hostView.convert(host.hostView.bounds, to: nil)))
    }

    /// A page window sits at the host view's screen rect to within 2 points.
    nonisolated static func frame(_ frame: CGRect, isPlacedAt rect: CGRect) -> Bool {
        abs(frame.minX - rect.minX) <= 2 && abs(frame.minY - rect.minY) <= 2
            && abs(frame.width - rect.width) <= 2 && abs(frame.height - rect.height) <= 2
    }
}
