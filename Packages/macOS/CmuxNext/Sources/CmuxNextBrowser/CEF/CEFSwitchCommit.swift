import AppKit
import CmuxNextWakeups

/// The app-wide LRU of hidden pages' and terminals' last frames (`HiddenFrameLRU`), as a
/// hosted page uses it. Chrome keeps one such list for every saved frame of the browser process
/// (`FrameEvictionManager`, components/viz/client/frame_eviction_manager.h): a shown frame is locked, a hidden
/// one waits unlocked and the least recently used unlocked frames go first. There is no per-pane limit.
@MainActor
public protocol CEFHiddenFrames: AnyObject {
    /// Adds `owner`'s frame, or makes it the most recent one: `locked` while its page shows (never evicted),
    /// unlocked while it is kept hidden. `evict` runs once, when the list drops the unlocked frame.
    func addFrame(_ owner: ObjectIdentifier, locked: Bool, evict: @escaping @MainActor () -> Void)
    /// `owner` keeps no frame any more (its page closed or stopped being hosted).
    func removeFrame(_ owner: ObjectIdentifier)
}

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
/// A hidden page's last frame stays with the fork (keep-frame-while-hidden), so a show puts it on screen
/// in the switch's own frame. ``CEFHiddenFrames`` decides how long: a shown page's frame is locked, a
/// hidden one is kept unlocked until the app-wide list evicts it, as Chrome's `DelegatedFrameHost`
/// locks its frame in `WasShown` and unlocks it in `WasHidden`. With no list every hidden frame goes
/// at once, so nothing grows without a bound.
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
    /// The page's hidden frame waits in the list (unlocked).
    private(set) var isFrameKept = false
    /// The fork dropped the hidden page window's frame (``evictFrame(browser:fork:)``); a show gives it back.
    private(set) var isFrameEvicted = false
    /// The fork took the hide and the list keeps no frame for it: the page is past its grace.
    var isPastGrace: Bool { applied != .visible && !isFrameKept }
    /// The app-wide list of kept frames; nil drops a hidden page's frame at once.
    weak var hiddenFrames: (any CEFHiddenFrames)?
    /// What a hidden page does when its grace ends (the layer hosting's snapshot); nil evicts at once.
    var pastGrace: ((_ browser: Int32, _ fork: CEFLayerHosting.Fork) -> Void)?

    /// The page's window's occlusion family subscription, and that window (``CEFLayerHosting/followWindowOcclusion()``).
    var occlusionWatch: WindowOcclusionSubscription?
    weak var occlusionWindow: NSWindow?

    private var held: HeldShow?
    private var isScheduled = false
    /// The page the fork took the last visibility for, so an eviction later reaches the same window.
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

    /// Gives the fork `wanted` when it differs from what the fork took; the page's frame is locked in
    /// the list while shown and kept unlocked while hidden. A refused call is tried at the next pass.
    ///
    /// The list's eviction of a hidden frame is the page's grace ending: ``pastGrace`` (the layer hosting's
    /// snapshot) takes it and calls ``evictFrame(browser:fork:)`` once its host is gone.
    func apply(_ wanted: CEFLayerHosting.PageVisibility, browser: Int32, fork: CEFLayerHosting.Fork) {
        target = (browser, fork)
        guard wanted != applied, let setVisibility = fork.setVisibility else { return }
        forkCalls += 1
        guard setVisibility(browser, wanted) else { return }
        applied = wanted
        switch wanted {
        case .visible:
            isFrameKept = false
            isFrameEvicted = false
            hiddenFrames?.addFrame(ObjectIdentifier(self), locked: true) {}
        case .occluded, .hidden:
            isFrameKept = true
            if let hiddenFrames {
                hiddenFrames.addFrame(ObjectIdentifier(self), locked: false) { [weak self] in self?.evict() }
            } else {
                evict()
            }
        case .window:
            isFrameKept = false
            hiddenFrames?.removeFrame(ObjectIdentifier(self))
        }
    }

    /// The page stopped being hosted, or its page window went: the fork keeps an embedder visibility across
    /// hosting off and on, so a value it took goes back to `window` (the page window's order decides again),
    /// and no frame is kept for it. A held show stays: its tab still needs its activation.
    func reset() {
        if target != nil || isFrameKept { hiddenFrames?.removeFrame(ObjectIdentifier(self)) }
        if applied != .window, let target, let setVisibility = target.fork.setVisibility {
            forkCalls += 1
            // A refusal means the page window is gone, and its value with it.
            _ = setVisibility(target.browser, .window)
        }
        applied = .window
        isFrameKept = false
        isFrameEvicted = false
        target = nil
    }

    /// The list dropped the hidden page's frame (or there is no list): the page is past its grace.
    private func evict() {
        guard isFrameKept, applied == .hidden || applied == .occluded, let target else { return }
        isFrameKept = false
        guard let pastGrace else { return evictFrame(browser: target.browser, fork: target.fork) }
        pastGrace(target.browser, target.fork)
    }

    /// The fork lets the hidden page window's kept frame go; the next show draws the page's snapshot, or
    /// its background, until Chromium's next frame.
    func evictFrame(browser: Int32, fork: CEFLayerHosting.Fork) {
        guard let evictFrame = fork.evictFrame else { return }
        forkCalls += 1
        if evictFrame(browser) { isFrameEvicted = true }
    }
}
