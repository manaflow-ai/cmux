import AppKit
import CmuxNextWakeups

/// What the person sees of a hosted page: `cmux_shim_page_visibility_t`, the value of
/// `cmux_shim_browser_set_page_visibility`, Chrome's `content::Visibility`
/// of a tab.
nonisolated enum ChromiumHostPageVisibility: Int32, Sendable {
    /// Shown: the page draws.
    case visible = 0
    /// Not shown: the page is hidden to its scripts and draws no frames.
    case hidden = 1
    /// On screen but covered: the page draws no frames (Chromium makes it hidden one second later).
    case occluded = 2

    init(_ visibility: Visibility) {
        switch visibility {
        case .visible: self = .visible
        case .occluded: self = .occluded
        case .hidden: self = .hidden
        }
    }

    /// What a window shows of its views.
    struct WindowState: Equatable, Sendable {
        /// Ordered in, not minimized, its app not hidden.
        var isShown: Bool
        /// No part of it is on screen (`NSWindow.occlusionState` lacks `.visible`).
        var isOccluded: Bool

        /// Chrome's rule for the window's part (`-[WebContentsViewCocoa updateWebContentsVisibility]`,
        /// content/app_shim_remote_cocoa/web_contents_view_cocoa.mm): occluded while the window is
        /// covered, else visible. A minimized window and a hidden app hide the page, as the fork's
        /// `CMUX_PAGE_HIDDEN` asks; a view out of every window (nil) is hidden.
        static func visibility(of state: WindowState?) -> Visibility {
            guard let state, state.isShown else { return .hidden }
            return state.isOccluded ? .occluded : .visible
        }
    }

    /// Where a page view reads its window's state and hears it change.
    struct Source {
        let windowState: @MainActor (NSWindow) -> WindowState
        /// The window's notifications, one observer per window (``WindowEvents``).
        let events: @MainActor (NSWindow) -> WindowEvents

        /// AppKit's state and the window's shared ``WindowEvents``.
        static var appKit: Source {
            Source(windowState: { window in
                WindowState(isShown: window.isVisible && !window.isMiniaturized && !(NSApp?.isHidden ?? false),
                            isOccluded: !window.occlusionState.contains(.visible))
            }, events: { WindowEvents.of($0) })
        }
    }
}

/// The page's visibility, as Chrome's page view keeps it for its WebContents
/// (`WebContentsViewCocoa`: `-viewDidMoveToWindow`, `-viewDidHide`, `-viewDidUnhide`,
/// `NSWindowDidChangeOcclusionStateNotification`): ``pageNode`` holds the view's own hidden state
/// under ``windowNode``, the window's; each flip of its effective state goes to
/// ``onPageVisibility``, which in host mode posts it to the Chromium Host.
extension ChromiumHostPageView {
    /// What the person sees of the page.
    var pageVisibility: ChromiumHostPageVisibility { ChromiumHostPageVisibility(pageNode.effective) }

    // AppKit sends these when the view or an ancestor is hidden or shown, and when the view enters
    // a hidden or a shown hierarchy.
    public override func viewDidHide() {
        super.viewDidHide()
        pageNode.set(.hidden)
    }

    public override func viewDidUnhide() {
        super.viewDidUnhide()
        pageNode.set(.visible)
    }

    /// Follows the window's minimize and occlusion (an app hide orders out every window, which
    /// changes its occlusion) and sets ``windowNode`` from it. Called when the view changes window
    /// and when the source changes.
    func observeVisibility() {
        visibilitySubscriptions = []
        guard let window else { return windowNode.set(.hidden) }
        let events = visibilitySource.events(window)
        let owner = "ChromiumHostPageView.visibility"
        let update: @MainActor () -> Void = { [weak self] in self?.updateWindowVisibility() }
        // Always delivered: the page's own visibility is what the host hides or shows it by.
        visibilitySubscriptions = [
            events.subscribe(NSWindow.didMiniaturizeNotification, owner: owner, update),
            events.subscribe(NSWindow.didDeminiaturizeNotification, owner: owner, update),
            events.subscribe(NSWindow.didChangeOcclusionStateNotification, owner: owner, update),
        ]
        updateWindowVisibility()
    }

    private func updateWindowVisibility() {
        windowNode.set(ChromiumHostPageVisibility.WindowState.visibility(of: window.map { visibilitySource.windowState($0) }))
    }

    /// Whether the page shows over this view, for the content invariant (``CEFTab/contentVisibility``
    /// in host mode): a context shows and the person can see the view. A covered window's page
    /// counts as shown, as an in-process page window does.
    var contentVisibility: BrowserContentVisibility {
        if pageVisibility == .hidden { return .hidden("page_view_hidden") }
        return contextID == 0 ? .hidden("no_context") : .visible
    }
}
