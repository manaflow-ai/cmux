import AppKit
import CmuxNextWakeups

extension CEFLayerHosting {
    /// Whether a show or hide of this view's page reaches the fork only after the switch's commit: the
    /// page is hosted (its layer goes in and out with the view's) and the fork takes its visibility from
    /// the app.
    var showsInSwitchTransaction: Bool { page != nil && fork?.setVisibility != nil }

    /// The shown tab's fork work (`CEFPaneHost.showBrowser`): its activation and the input window's
    /// re-place, after this turn's commit; the last show of the turn wins.
    func showAfterCommit(activate: (@MainActor () -> Void)?, place: @escaping @MainActor () -> Void) {
        switchCommit.hold(CEFSwitchCommit.HeldShow(activate: activate, place: place))
        setNeedsCommitPass()
    }

    /// The content lifecycle hid or showed the view, the view changed windows (`CEFHostView`), or its window
    /// was occluded or seen again: a hosted page's visibility reaches the fork after the commit, once,
    /// whatever the turn changed back and forth.
    func visibilityMayHaveChanged() {
        followWindowOcclusion()
        guard showsInSwitchTransaction else { return }
        // A page shown past its grace puts its snapshot and its layer host back in this transaction.
        if pageVisibility == .visible { showHiddenSnapshot() }
        setNeedsCommitPass()
    }

    /// The content lifecycle's state for this page: the view's own flag (`CEFTab.setContentVisible`).
    var isViewShown: Bool {
        guard let view else { return false }
        return view.window != nil && !view.isHidden
    }

    func setNeedsCommitPass() {
        switchCommit.setNeedsPass { [weak self] in self?.commitPass() }
    }

    /// After the switch's commit: the shown tab's activation, the page's visibility (a call only when it
    /// changed), a changed resize deadline, then the input window's place.
    private func commitPass() {
        let held = switchCommit.takeHeld()
        held?.activate?()
        if showsInSwitchTransaction, let fork, let browser {
            let visibility = pageVisibility
            switchCommit.apply(visibility, browser: browser, fork: fork)
            // The renderer hears the show now; its next frame takes the snapshot away. Hidden or occluded: a
            // page past its grace that showed and hid again in this turn goes back past its grace.
            if visibility == .visible { awaitFrameUnderSnapshot(browser: browser, fork: fork) } else { keepPastGrace(browser: browser, fork: fork) }
        }
        syncDeadline()
        held?.place()
    }

    /// A page window's visibility as the app gives it to the fork: the raw values are the shim's
    /// `cmux_shim_embedder_visibility_t` (`cmux_shim_browser_set_embedder_visibility`).
    /// `visible`, `occluded` and `hidden` mean Chrome's `content::Visibility` (content/public/browser/visibility.h).
    nonisolated enum PageVisibility: Int32, Sendable {
        /// The page window's order and occlusion decide (the fork's default).
        case window = 0
        case visible = 1
        case occluded = 2
        case hidden = 3
    }
}

/// The fork work of a hosted page's show or hide, run once after the switch's commit,
/// for one ``CEFLayerHosting``.
///
/// In the switch's turn the page's layer only goes in or out with its view, so the switch's frame has
/// no fork call in it. After that commit one pass runs what the turn left: the shown tab's activation
/// (Chromium's `WasShown` and `WasHidden` of the two tabs), the page window's visibility when it
/// changed, and the input window's place. A turn that hid and showed the page again makes no call.
///
/// A hidden page is past its grace as soon as the fork takes the hide: ``pastGrace`` (the layer hosting's
/// snapshot) takes its last frame and the fork lets the frame go, so no hidden frame waits without a bound.
final class CEFSwitchCommit {
    /// The shown tab's work held for the pass (`CEFPaneHost.showBrowser`).
    struct HeldShow {
        /// Makes the tab Chromium's active one; nil when Chromium already made it active.
        let activate: (@MainActor () -> Void)?
        /// Re-places the input window over the view.
        let place: @MainActor () -> Void
    }

    /// Visibility and eviction calls into the fork so far.
    private(set) var forkCalls = 0
    /// The visibility the fork took last: a page window starts with its window's order and occlusion deciding.
    private(set) var applied = CEFLayerHosting.PageVisibility.window
    /// The fork dropped the hidden page window's frame (``evictFrame(browser:fork:)``); a show gives it back.
    private(set) var isFrameEvicted = false
    /// The fork took the hide (or the page is not visible to it): the page is past its grace.
    var isPastGrace: Bool { applied != .visible }
    /// What a hidden page does when its grace ends (the layer hosting's snapshot); nil evicts at once.
    var pastGrace: ((_ browser: Int32, _ fork: CEFLayerHosting.Fork) -> Void)?

    /// The page's window's occlusion family subscription, and that window (``CEFLayerHosting/followWindowOcclusion()``).
    var occlusionWatch: WindowOcclusionSubscription?
    weak var occlusionWindow: NSWindow?

    private var held: HeldShow?
    private var isScheduled = false
    /// The page the fork took the last visibility for, so a reset later reaches the same window.
    private var target: (browser: Int32, fork: CEFLayerHosting.Fork)?
    private let afterCommit: CEFLayerHosting.Scheduler

    init(afterCommit: @escaping CEFLayerHosting.Scheduler) {
        self.afterCommit = afterCommit
    }

    /// Whether a pass waits for this turn's commit.
    var isPassPending: Bool { isScheduled }

    /// The last show of this turn replaces an earlier one: one activation per pass.
    func hold(_ show: HeldShow) {
        held = show
    }

    /// Takes the held show for the pass.
    func takeHeld() -> HeldShow? {
        defer { held = nil }
        return held
    }

    /// Queues one pass after this turn's commit; later calls in the same turn join it.
    func setNeedsPass(_ pass: @escaping @MainActor @Sendable () -> Void) {
        guard !isScheduled else { return }
        isScheduled = true
        afterCommit { [weak self] in
            self?.isScheduled = false
            pass()
        }
    }

    /// Gives the fork `wanted` when it differs from what the fork took. A refused call is tried at the next
    /// pass.
    ///
    /// A hide the fork took ends the page's grace: ``pastGrace`` (the layer hosting's snapshot) takes the
    /// frame and calls ``evictFrame(browser:fork:)`` once its host is gone.
    func apply(_ wanted: CEFLayerHosting.PageVisibility, browser: Int32, fork: CEFLayerHosting.Fork) {
        target = (browser, fork)
        guard wanted != applied, let setVisibility = fork.setVisibility else { return }
        forkCalls += 1
        guard setVisibility(browser, wanted) else { return }
        applied = wanted
        switch wanted {
        case .visible:
            isFrameEvicted = false
        case .occluded, .hidden:
            guard let pastGrace else { return evictFrame(browser: browser, fork: fork) }
            pastGrace(browser, fork)
        case .window:
            break
        }
    }

    /// The page stopped being hosted, or its page window went: the fork keeps an embedder visibility across
    /// hosting off and on, so a value it took goes back to `window` (the page window's order decides again).
    /// A held show stays: its tab still needs its activation.
    func reset() {
        if applied != .window, let target, let setVisibility = target.fork.setVisibility {
            forkCalls += 1
            // A refusal means the page window is gone, and its value with it.
            _ = setVisibility(target.browser, .window)
        }
        applied = .window
        isFrameEvicted = false
        target = nil
    }

    /// The fork lets the hidden page window's kept frame go; the next show draws the page's snapshot, or
    /// its background, until Chromium's next frame.
    func evictFrame(browser: Int32, fork: CEFLayerHosting.Fork) {
        guard let evictFrame = fork.evictFrame else { return }
        forkCalls += 1
        if evictFrame(browser) { isFrameEvicted = true }
    }
}
