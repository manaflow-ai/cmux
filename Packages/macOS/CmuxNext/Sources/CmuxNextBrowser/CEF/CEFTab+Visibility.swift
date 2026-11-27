public import AppKit

extension CEFTab: BrowserContentVisibilityReporting {
    /// Whether the page shows over this tab's content view. With child-window pages, the page window there: a visible,
    /// non-panel child of the host window whose frame matches the host view's screen rect. In tree, the page's own view
    /// in the host's in-tree container (``CEFInTreeHosting/pageVisibility(in:)``): an in-tree page has no page window,
    /// and read through one it was hidden (`page_window_missing`) and its pane blank in `debug.surfaces` while it painted.
    public var contentVisibility: BrowserContentVisibility {
        guard !isClosed else { return .hidden("closed") }
        guard let window = container.window else { return .hidden("not_in_window") }
        guard host.visibleTab === self, host.hostView.superview === container else { return .hidden("host_elsewhere") }
        guard !host.hostView.isHiddenOrHasHiddenAncestor else { return .hidden("host_hidden") }
        guard browserID != nil else { return .hidden("no_page") }
        if presentation == .inTree { return host.hostView.inTree.pageVisibility(in: window) }
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

    /// Whether the keys typed in `window`, the key window, reach this tab's page. With child-window pages, `window` is
    /// its page window (``isPageWindow(_:)``). In tree, `window` is the cmux window this tab shows in and its first
    /// responder is in the page's container (``CEFInTreeHosting/hasTheKeyboard``): no window is the page's there. The
    /// key router offers such a page its own Find first (`KeyRouter.pageHasKeys`).
    ///
    /// - Parameter window: The window a key-down goes to.
    /// - Returns: Whether this tab's page has that window's keyboard.
    public func pageHasKeyboard(in window: NSWindow) -> Bool {
        guard presentation == .inTree else { return isPageWindow(window) }
        return showsInTree(in: window) && host.hostView.inTree.hasTheKeyboard
    }

    /// Whether `view` is a view of this tab's page: in tree a view in the host's in-tree container, else a view of its
    /// page window (``isPageWindow(_:)``).
    func ownsPageView(_ view: NSView) -> Bool {
        guard let window = view.window else { return false }
        guard presentation == .inTree else { return isPageWindow(window) }
        guard showsInTree(in: window), let pageContainer = host.hostView.inTree.container else { return false }
        return view.isDescendant(of: pageContainer)
    }

    /// The host shows this tab in `window` with its page in the tree.
    private func showsInTree(in window: NSWindow) -> Bool {
        !isClosed && container.window === window && host.visibleTab === self && host.hostView.superview === container
            && host.hostView.inTree.isInTree
    }

    /// Chromium's page window over this tab's content view (``isPageWindow(_:)``), if it shows one.
    var pageWindow: NSWindow? { container.window?.childWindows?.first(where: isPageWindow) }

    /// A page window sits at the host view's screen rect to within 2 points.
    nonisolated static func frame(_ frame: CGRect, isPlacedAt rect: CGRect) -> Bool {
        abs(frame.minX - rect.minX) <= 2 && abs(frame.minY - rect.minY) <= 2
            && abs(frame.width - rect.width) <= 2 && abs(frame.height - rect.height) <= 2
    }
}

public extension BrowserTab {
    /// The page can take keys: Chromium created its browser, a real document loaded, and no focus ask of it waits for its
    /// grant (a page shown in this turn gets the keys after the turn's frame commit; a key typed before that reached no
    /// view). A non-Chromium page always can.
    var pageReady: Bool { (self as? CEFTab).map { $0.browserID != nil && $0.hasDocument && !$0.pendingFocus } ?? true }
    /// Chromium created the page (its address bar works; its document may still load).
    var pageCreated: Bool { (self as? CEFTab).map { $0.browserID != nil } ?? true }
}
