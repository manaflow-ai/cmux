import CmuxNextWakeups

/// What Chromium hears of a ``CEFTab``'s visibility tree node, and the page freeze that follows a hide
/// (plans/cmux-next/chrome-parity/p06-scheduler.md, section B; task 212).
///
/// The tab's node reaches Chromium through the fork's `cmux_tab_set_visibility` (fork API 37), as Chrome's tab
/// strip hides a background tab's WebContents (chrome/browser/ui/views/frame/browser_view.cc `OnActiveTabChanged`,
/// content/browser/web_contents/web_contents_impl.cc `UpdateWebContentsVisibility`). The node's value caps what the
/// page window and its view ask for, so a hidden tab is hidden to Blink in the node's own turn:
/// `document.visibilityState` reads `hidden` before the next frame, and requestAnimationFrame and rendering stop.
/// Blink's hidden-page throttling then runs in the renderer, and the freeze (`browser.freezeHiddenTabs`) stays the
/// second step: a tab that follows its node freezes only once Chromium took it hidden with no capture, as Chrome's
/// freezing policy leaves visible and captured pages alone (components/performance_manager/freezing/
/// freezing_policy.cc). A capture keeps a hidden tab painting (`WebContents::IncrementCapturerCount`). Without the
/// call (``CEFForkFeatures/tabVisibility``) the tab follows no node and its page window decides alone, as before.
final class CEFTabNodeVisibility {
    /// The shim's `cmux_shim_tab_visibility_t`: a cap on what the page window and its view ask for.
    nonisolated enum Level: Int32, Sendable {
        /// No cap: the page window decides (the fork's default).
        case view = 0
        case visible = 1
        case occluded = 2
        case hidden = 3

        init(_ visibility: Visibility) {
            switch visibility {
            case .visible: self = .visible
            case .occluded: self = .occluded
            case .hidden: self = .hidden
            }
        }
    }

    /// One `cmux_shim_tab_set_visibility` call.
    nonisolated struct Sent: Equatable, Sendable {
        let browser: Int32
        let visibility: Level
        let capture: BrowserPageCapture
    }

    private weak var tab: CEFTab?
    /// The node the tab follows, held while it does (`TabContentCache.node(for:)` keeps nodes weakly).
    private(set) var node: VisibilityNode?
    private var capture: (@MainActor (VisibilityNode) -> BrowserPageCapture)?
    private var subscriptions: [VisibilitySubscription] = []
    /// What Chromium took last; another browser (a new id) has heard nothing.
    private(set) var sent: Sent?
    /// ``setFrozen(_:of:)`` froze the page and nothing thawed it since.
    private(set) var isPageFrozen = false

    /// ``CEFTab/followVisibility(of:capture:)``: `tab` follows `node` from now, until it follows another node or this
    /// value goes with the tab. False, changing nothing, for a closed tab or a fork without the call.
    func follow(_ node: VisibilityNode, capture: @escaping @MainActor (VisibilityNode) -> BrowserPageCapture, of tab: CEFTab) -> Bool {
        guard !tab.isClosed, tab.runtime.forkFeatures.tabVisibility else { return false }
        subscriptions.forEach { $0.cancel() }
        self.tab = tab
        self.node = node
        self.capture = capture
        subscriptions = [
            node.subscribe(owner: "CEFTab.visibility") { [weak self] _ in self?.apply() },
            node.subscribeExemption(owner: "CEFTab.capture") { [weak self] in self?.apply() },
        ]
        apply()
        return true
    }

    /// Gives Chromium the node's value when it differs from what the tab's browser took last; a new browser
    /// (`CEFTab.attach`) hears it before it paints. A frozen tab shown or captured again thaws first, while Chromium
    /// still counts it hidden: Chromium never shows a frozen page (`WebContentsImpl::SetPageFrozen`), and a capture is
    /// a reason not to freeze that unfreezes the page (freezing_policy.cc `CannotFreezeReason`).
    func apply() {
        guard let tab, let browser = tab.browserID, !tab.isClosed, let wanted = wanted(browser: browser),
              wanted != sent, let call = tab.runtime.shim?.tabSetVisibility else { return }
        if isPageFrozen, wanted != Sent(browser: browser, visibility: .hidden, capture: .notCaptured) { _ = setFrozen(false, of: tab) }
        // One-way, in call order (a post to the Chromium Host): a freeze sent later reaches Chromium after it.
        _ = call(browser, wanted.visibility.rawValue, wanted.capture.rawValue)
        sent = wanted
    }

    /// The call `browser` needs now; nil while the tab follows no node.
    func wanted(browser: Int32) -> Sent? {
        guard let node, let capture else { return nil }
        return Sent(browser: browser, visibility: Level(node.effective), capture: capture(node))
    }

    /// ``CEFTab/setFrozen(_:)``. A tab that follows its node freezes only after Chromium took it hidden with no
    /// capture; one that follows none freezes as before. Sent now, not from a Task: an agent call queued right after
    /// a thaw must not reach a frozen page. A thaw of a page that is not frozen sends nothing: the node's capture
    /// thaws the page in its own turn, and the hibernation's thaw can come after it.
    func setFrozen(_ frozen: Bool, of tab: CEFTab) -> Bool {
        guard let browser = tab.browserID, !tab.isClosed, let shim = tab.runtime.shim else { return false }
        if !frozen, !isPageFrozen { return true }
        if frozen, node != nil, sent != Sent(browser: browser, visibility: .hidden, capture: .notCaptured) { return false }
        let done: Bool
        if tab.runtime.forkFeatures.rendererPaths, let setFrozen = shim.tabSetFrozen {
            done = setFrozen(browser, frozen ? 1 : 0) == 1
        } else {
            // No one waits for the reply (the runtime drops a reply without a waiter).
            done = tab.runtime.sendDevTools(browser, method: "Page.setWebLifecycleState", params: ["state": frozen ? "frozen" : "active"]) != nil
        }
        if done { isPageFrozen = frozen }
        return done
    }

    /// ``CEFTab/freezeShownInOffScreenWindow()``: the page an off-screen window shows. A tab that
    /// follows its node was hidden to Chromium by the window node and freezes as a hidden page. One that follows none
    /// (a fork before API 37) still counts visible to Chromium, so `SetPageFrozen` would refuse it: DevTools
    /// `Page.setWebLifecycleState` hides it first (`WasHidden`), as for a page that is never shown. Its thaw is
    /// ``setFrozen(_:of:)`` with `false`, sent now, so an agent call after it reaches a live page.
    func freezeShown(of tab: CEFTab) -> Bool {
        guard node == nil else { return setFrozen(true, of: tab) }
        guard let browser = tab.browserID, !tab.isClosed else { return false }
        if isPageFrozen { return true }
        if tab.runtime.sendDevTools(browser, method: "Page.setWebLifecycleState", params: ["state": "frozen"]) != nil { isPageFrozen = true }
        return isPageFrozen
    }

    /// Freezes a page that is never shown: the spare window's about:blank placeholder, on a fork with no
    /// renderer-less placeholder. Unfrozen, the placeholder counted visible and ran rAF at ~98/s at idle (fleet probe
    /// 4e065838, macOS 27). It is never thawed: a take closes it on the next turn (`CEFPaneHost.closeSparePlaceholder`).
    ///
    /// From fork API 37 it is hidden to Chromium (`cmux_shim_tab_set_visibility`), then frozen with `SetPageFrozen`
    /// (which freezes only hidden pages), opening no DevTools session, so its renderer stays shareable. Before, through
    /// DevTools `Page.setWebLifecycleState`, which hides it to Chromium first (`WasHidden`):
    /// `CefBrowserHost::WasHidden` does nothing for a windowed Chrome-style browser.
    static func freezeNeverShown(_ browser: Int32, runtime: CEFRuntime) {
        guard let shim = runtime.shim else { return }
        let features = runtime.forkFeatures
        if features.tabVisibility, features.rendererPaths, let hide = shim.tabSetVisibility, let freeze = shim.tabSetFrozen {
            _ = hide(browser, Level.hidden.rawValue, BrowserPageCapture.notCaptured.rawValue)
            _ = freeze(browser, 1)
            return
        }
        runtime.sendDevTools(browser, method: "Page.setWebLifecycleState", params: ["state": "frozen"])
    }
}
