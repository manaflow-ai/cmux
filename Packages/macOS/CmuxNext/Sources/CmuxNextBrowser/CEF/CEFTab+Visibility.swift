public import AppKit
public import CmuxNextDesign
public import CmuxNextWakeups

// Chromium follows the tab's visibility tree node through `nodeVisibility` (``CEFTabNodeVisibility``).
extension CEFTab: BrowserContentVisibilityReporting, BrowserVisibilityFollowing {
    @discardableResult
    public func followVisibility(of node: VisibilityNode, capture: @escaping @MainActor (VisibilityNode) -> BrowserPageCapture) -> Bool {
        nodeVisibility.follow(node, capture: capture, of: self)
    }

    /// Whether this tab's page draws over its content view. Host mode: what the pane's page view
    /// shows (``ChromiumHostPageView/contentVisibility``), since the host's
    /// page windows are never in cmux. In process: the fork's page window over the view.
    public var contentVisibility: BrowserContentVisibility {
        guard !isClosed else { return .hidden("closed") }
        guard let window = container.window else { return .hidden("not_in_window") }
        guard host.visibleTab === self, host.hostView.superview === container else { return .hidden("host_elsewhere") }
        guard !host.hostView.isHiddenOrHasHiddenAncestor else { return .hidden("host_hidden") }
        guard browserID != nil else { return .hidden("no_page") }
        if host.isHostMode { return host.hostedPageView?.contentVisibility ?? .hidden("no_page_view") }
        return inProcessPageWindowVisibility(in: window)
    }

    /// In process: a visible, non-panel child of the host window whose frame matches the host
    /// view's screen rect.
    private func inProcessPageWindowVisibility(in window: NSWindow) -> BrowserContentVisibility {
        let rect = window.convertToScreen(host.hostView.convert(host.hostView.bounds, to: nil))
        let pages = (window.childWindows ?? []).filter { !($0 is NSPanel) && !devToolsContains(window: $0) }
        let placed = pages.filter { Self.frame($0.frame, isPlacedAt: rect) }
        if placed.contains(where: \.isVisible) { return .visible }
        if !placed.isEmpty { return .hidden("page_window_hidden") }
        return .hidden(pages.contains(where: \.isVisible) ? "page_window_misplaced" : "page_window_missing")
    }

    /// Whether this tab is the one its pane host shows, not hidden by the content lifecycle, in a visible
    /// window: Chrome's `WebContents::GetVisibility() == Visibility::VISIBLE` for its startup tab.
    var isShownInVisibleWindow: Bool {
        guard !isClosed, host.visibleTab === self, !isContentHidden, let window = container.window else { return false }
        return window.isVisible
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

    /// Chromium Host: whether this tab's page view (``ChromiumHostPageView/InputTarget/view``) is
    /// `window`'s first responder and its host reports the chords the page leaves unhandled
    /// (``ChromiumHostPageView/hostReportsUnhandledKeys``), so the page gets
    /// page-ownable keys first.
    public func hostedPageHasKeys(in window: NSWindow) -> Bool {
        guard !isClosed, host.visibleTab === self, let page = host.hostedPageView, page.inputTarget == .view,
              page.hostReportsUnhandledKeys else { return false }
        return window.firstResponder === page
    }

    /// Chromium Host: whether this tab's page view is `window`'s first responder and its page holds a
    /// keyboard lock in its fullscreen (``ChromiumHostExclusiveAccess/holdsKeys``).
    public func hostedPageLocksKeys(in window: NSWindow) -> Bool {
        guard !isClosed, host.visibleTab === self, let page = host.hostedPageView, window.firstResponder === page else { return false }
        return page.exclusiveAccess.holdsKeys
    }

    /// Where this tab's page draws (``BrowserBackend/pageSurface`` of the process's backend): a window
    /// that shows it (its DevTools window, a popup window) takes the child-window machinery only in process.
    public var pageSurface: PageSurface { (host.isHostMode ? BrowserBackend.host : .inProcess).pageSurface }

    /// A page window sits at the host view's screen rect to within 2 points.
    nonisolated static func frame(_ frame: CGRect, isPlacedAt rect: CGRect) -> Bool {
        abs(frame.minX - rect.minX) <= 2 && abs(frame.minY - rect.minY) <= 2
            && abs(frame.width - rect.width) <= 2 && abs(frame.height - rect.height) <= 2
    }

    // MARK: Content view

    func contentDidAppear(in view: CEFTabContentView) {
        guard !isClosed else { return }
        host.present(self, in: view)
        view.layoutContent()
        if reloadWhenShown {
            reloadWhenShown = false
            if state.processExit != nil { reload() }
        }
        hostRestoreShown()
        rendererHangVisibilityChanged()
    }

    func contentDidDisappear() {
        host.conceal(self)
        rendererHangVisibilityChanged()
    }
}
