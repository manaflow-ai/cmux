import AppKit
@testable import CmuxNextBrowser
import CmuxNextTestSupport
import CmuxNextWakeups
import Testing

/// Detached hosting in a resize motion (fork API 30, STATUS 14261 slice 1), without Chromium: a fake fork records
/// every detach and attach. A layer-hosted page that does not hold the keys leaves the parent window for a divider
/// drag, a key resize or a window live resize, so the fork's per-frame tracker update moves no WindowServer window;
/// it comes back once at the landing. The page that holds the keys stays a page window (no key-window change).
@MainActor
@Suite(.closesItsWindows) struct CEFDetachedMotionTests {
    final class FakeFork {
        private(set) var detaches: [(browser: Int32, on: Bool)] = []
        var accepts = true
        var fork: CEFLayerHosting.Fork {
            CEFLayerHosting.Fork(setLayerHosting: { _, enabled in enabled ? 7 : 0 }, setResizeSync: { _, _ in true },
                                 setDetachedHosting: { [self] browser, on in
                                     detaches.append((browser, on))
                                     return accepts
                                 })
        }
    }

    let fake = FakeFork()
    let view = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))

    /// A hosted page (its context shown) of browser 4.
    func hostedPage(focus: @escaping () -> Bool = { false }, fork: CEFLayerHosting.Fork? = nil) -> CEFLayerHosting {
        var blocks: [@MainActor @Sendable () -> Void] = []
        let hosting = CEFLayerHosting(isEnabled: { true }, schedule: { blocks.append($0) },
                                      makePage: { CEFHostedPageView(frame: $0, makeLayerHost: { _ in CALayer() }) },
                                      holdsFocus: focus)
        hosting.view = view
        hosting.pageWindowCreated(browser: 4, fork: fork ?? fake.fork)
        for block in blocks { block() }
        #expect(hosting.page != nil)
        return hosting
    }

    var calls: [String] { fake.detaches.map { "\($0.browser):\($0.on ? "detach" : "attach")" } }

    @Test func aMotionDetachesAnUnfocusedPageAndAttachesItOnceAtTheLanding() {
        let hosting = hostedPage()
        hosting.resizeMotion(active: true)
        #expect(calls == ["4:detach"])
        #expect(hosting.isDetached)
        hosting.resizeMotion(active: false)
        #expect(calls == ["4:detach", "4:attach"])
        #expect(!hosting.isDetached)
    }

    @Test func thePageThatHoldsTheKeysStaysAttachedThroughTheMotion() {
        let hosting = hostedPage(focus: { true })
        hosting.resizeMotion(active: true)
        hosting.resizeMotion(active: false)
        #expect(calls.isEmpty, "detaching the key window would move the keys")
    }

    @Test func focusMidMotionAttachesAtOnceAndKeepsThePageAttached() {
        let hosting = hostedPage()
        hosting.resizeMotion(active: true)
        #expect(hosting.pageTakesFocus())
        #expect(calls == ["4:detach", "4:attach"])
        hosting.resizeMotion(active: false)
        #expect(calls == ["4:detach", "4:attach"], "the landing has nothing to attach")
        #expect(!hosting.pageTakesFocus(), "outside a motion the page is a page window already")
    }

    /// Every tab container of the pane tells its own start and end: the page attaches when the last one ends.
    @Test func theMotionLastsUntilEveryContainerEnded() {
        let hosting = hostedPage()
        hosting.resizeMotion(active: true)
        hosting.resizeMotion(active: true)
        hosting.resizeMotion(active: false)
        #expect(calls == ["4:detach"])
        hosting.resizeMotion(active: false)
        hosting.resizeMotion(active: false)
        #expect(calls == ["4:detach", "4:attach"])
    }

    @Test func aWindowLiveResizeIsAMotionToo() {
        let hosting = hostedPage()
        hosting.windowLiveResize(active: true)
        hosting.resizeMotion(active: true)
        hosting.windowLiveResize(active: false)
        #expect(calls == ["4:detach"], "the drag still runs")
        hosting.resizeMotion(active: false)
        #expect(calls == ["4:detach", "4:attach"])
    }

    @Test func belowForkAPI30NothingReachesTheFork() {
        let hosting = hostedPage(fork: CEFLayerHosting.Fork(setLayerHosting: { _, on in on ? 7 : 0 }))
        hosting.resizeMotion(active: true)
        #expect(!hosting.isDetached)
        hosting.resizeMotion(active: false)
        #expect(calls.isEmpty)
    }

    @Test func aRefusalLeavesThePageAttached() {
        fake.accepts = false
        let hosting = hostedPage()
        hosting.resizeMotion(active: true)
        #expect(!hosting.isDetached)
        hosting.resizeMotion(active: false)
        #expect(calls == ["4:detach"], "nothing to attach after a refusal")
    }

    /// The page window closed mid-motion: nothing reaches the fork for it, and the next page starts attached.
    @Test func aPageWindowClosedMidMotionEndsTheMotion() {
        let hosting = hostedPage()
        hosting.resizeMotion(active: true)
        hosting.stop()
        #expect(!hosting.isDetached)
        hosting.resizeMotion(active: false)
        #expect(calls == ["4:detach"])
    }

    /// The host view left its window (or moved to another) while its page was detached: the old window never ends a
    /// live resize or a drag for a view that left it, and a detached page takes no input, so it attaches at once and
    /// stays attached for the rest of that motion.
    @Test func aDetachedPageWhoseViewLeavesItsWindowAttachesAtOnce() {
        let hosting = hostedPage()
        hosting.windowLiveResize(active: true)
        #expect(calls == ["4:detach"])
        // `view` is in no window: the window change reads no live resize.
        hosting.windowDidChange()
        #expect(calls == ["4:detach", "4:attach"])
        #expect(!hosting.isDetached)
    }

    @Test func aDetachedPageWhoseViewMovesWindowsMidDragStaysAttachedToTheLanding() {
        let hosting = hostedPage()
        hosting.resizeMotion(active: true)
        hosting.windowDidChange()
        #expect(calls == ["4:detach", "4:attach"])
        hosting.resizeMotion(active: false)
        #expect(calls == ["4:detach", "4:attach"], "the landing has nothing more to attach")
    }

    /// Leo 2026-11-06 (nightly d7d50e5, load 130+): a pane whose split closed stayed unclickable. A landing whose attach
    /// the fork refused left the page window headless with nothing to retry it: the page showed but took no click. The
    /// attach is owed and retried at the next tracker read, show or browser change until the fork takes it.
    @Test func anAttachTheForkRefusedAtTheLandingIsRetriedUntilItTakes() {
        let hosting = hostedPage()
        hosting.resizeMotion(active: true)
        fake.accepts = false
        hosting.resizeMotion(active: false)
        #expect(hosting.isDetached && hosting.attachOwed, "the refused attach is owed")
        hosting.trackerDidRead()
        #expect(hosting.isDetached, "still refused")
        fake.accepts = true
        hosting.trackerDidRead()
        #expect(!hosting.isDetached && !hosting.attachOwed, "the next read attaches the page window")
        #expect(calls == ["4:detach", "4:attach", "4:attach", "4:attach"])
        hosting.trackerDidRead()
        #expect(calls.count == 4, "nothing more reaches the fork once attached")
    }

    /// A renderer restart names the page window by another browser while it is detached: the owed attach goes to it.
    @Test func anOwedAttachFollowsTheBrowserThatNamesThePageWindowNow() {
        let hosting = hostedPage()
        hosting.resizeMotion(active: true)
        fake.accepts = false
        hosting.resizeMotion(active: false)
        fake.accepts = true
        hosting.windowBrowsersChanged([9])
        #expect(!hosting.isDetached)
        #expect(calls.last == "9:attach")
    }

    /// A new motion before the retry owns the page window again: it lands with one attach, not one per read.
    @Test func aMotionStartedBeforeTheRetryLandsWithItsOwnAttach() {
        let hosting = hostedPage()
        hosting.resizeMotion(active: true)
        fake.accepts = false
        hosting.resizeMotion(active: false)
        fake.accepts = true
        hosting.resizeMotion(active: true)
        hosting.trackerDidRead()
        #expect(hosting.isDetached && !hosting.attachOwed, "mid-motion the page stays detached")
        hosting.resizeMotion(active: false)
        #expect(!hosting.isDetached)
    }

    // MARK: The frame a page shows in (SWITCH STALL 5)

    /// A hosted page whose blocks after a commit (`commit`) and after the next display frame (`frame`) the test runs
    /// (``CEFLayerHosting/pageAppeared(windowInWindow:then:)``).
    func shownPage() -> (CEFLayerHosting, commit: @MainActor () -> Void, frame: @MainActor () -> Void) {
        var blocks: [@MainActor @Sendable () -> Void] = []
        var committed: [@MainActor @Sendable () -> Void] = []
        var framed: [@MainActor @Sendable () -> Void] = []
        let hosting = CEFLayerHosting(isEnabled: { true }, schedule: { blocks.append($0) },
                                      makePage: { CEFHostedPageView(frame: $0, makeLayerHost: { _ in CALayer() }) },
                                      holdsFocus: { false }, afterCommit: { committed.append($0) },
                                      afterFrameShown: { framed.append($0) })
        hosting.view = view
        hosting.pageWindowCreated(browser: 4, fork: fake.fork)
        for block in blocks { block() }
        #expect(hosting.page != nil)
        return (hosting, {
            let pass = committed
            committed.removeAll()
            for block in pass { block() }
        }, {
            let pass = framed
            framed.removeAll()
            for block in pass { block() }
        })
    }

    /// Cmd-N's page shows in the key's turn with its window out of the window: detached in that turn (no window order
    /// before the first frame), attached once that frame came (not at the key's commit, which comes before the frame's
    /// display tick), and the focus grant comes one pass later, after the fork's order-in. A grant asked meanwhile waits.
    @Test func aPageShownWithItsWindowOutAttachesAfterTheFrameAndGrantsAfterTheAttach() {
        let (hosting, commit, frame) = shownPage()
        var grants = 0
        hosting.pageAppeared(windowInWindow: false) { grants += 1 }
        #expect(calls == ["4:detach"])
        #expect(hosting.holdsFirstFrame(), "no window to make key in the turn it showed: a grant keeps its ask")
        #expect(!hosting.pageTakesFocus(), "the hold's end grants: a grant does not wait for each commit meanwhile")
        commit()
        #expect(calls == ["4:detach"], "the key's commit alone does not attach: its frame's display tick has not come")
        frame()
        #expect(calls == ["4:detach", "4:attach"])
        #expect(grants == 0, "the fork orders the window in at its next observer")
        #expect(hosting.holdsFirstFrame())
        commit()
        #expect(grants == 1)
        #expect(!hosting.holdsFirstFrame() && !hosting.isDetached && hosting.firstFrameHold == .none)
    }

    /// A page whose window is already in the window (a tab switch inside its pane) is left alone.
    @Test func aPageShownWithItsWindowInIsLeftAlone() {
        let (hosting, commit, frame) = shownPage()
        var grants = 0
        hosting.pageAppeared(windowInWindow: true) { grants += 1 }
        frame()
        commit()
        #expect(calls.isEmpty && grants == 0 && hosting.firstFrameHold == .none)
    }

    /// A motion that began before the frame owns the detached page: no attach at the frame, one at the landing.
    @Test func aMotionStartedInTheShowTurnAttachesOnlyAtItsLanding() {
        let (hosting, _, frame) = shownPage()
        var grants = 0
        hosting.pageAppeared(windowInWindow: false) { grants += 1 }
        hosting.resizeMotion(active: true)
        frame()
        #expect(calls == ["4:detach"] && grants == 1 && hosting.isDetached)
        hosting.resizeMotion(active: false)
        #expect(calls == ["4:detach", "4:attach"])
    }

    /// The page window closed before the frame: nothing reaches the fork for it after.
    @Test func aPageWindowClosedBeforeTheFrameIsNotAttached() {
        let (hosting, commit, frame) = shownPage()
        hosting.pageAppeared(windowInWindow: false) {}
        hosting.stop()
        frame()
        commit()
        #expect(calls == ["4:detach"] && hosting.firstFrameHold == .none)
    }

    /// The fork refuses the attach after the frame: the page has no window to make key, so the hold ends with no grant
    /// (the tab keeps its ask) and the attach is owed for the next retry.
    @Test func aRefusedAttachAfterTheFrameEndsTheHoldWithNoGrant() {
        let (hosting, commit, frame) = shownPage()
        var grants = 0
        hosting.pageAppeared(windowInWindow: false) { grants += 1 }
        fake.accepts = false
        frame()
        commit()
        #expect(calls == ["4:detach", "4:attach"] && hosting.attachOwed && hosting.isDetached)
        commit()
        #expect(grants == 0 && !hosting.holdsFirstFrame())
    }

    /// The fork refused the attach after the frame, and a later retry (a tracker read) attaches: the kept ask is
    /// granted once, after the commit that orders the window in (#37175 gap: the retry attached and granted nothing).
    @Test func aRetriedAttachGrantsTheKeptAskOnce() {
        let (hosting, commit, frame) = shownPage()
        var grants = 0
        hosting.pageAppeared(windowInWindow: false) { grants += 1 }
        fake.accepts = false
        frame()
        commit()
        commit()
        #expect(grants == 0 && hosting.attachOwed)
        fake.accepts = true
        hosting.trackerDidRead()
        #expect(!hosting.isDetached && grants == 0, "the fork orders the window in at its next observer")
        commit()
        #expect(grants == 1)
        hosting.trackerDidRead()
        commit()
        #expect(grants == 1, "one grant")
    }

    /// A motion that began while the attach was owed owns the page: its landing attaches it and grants the kept ask.
    @Test func aMotionLandingThatAttachesAnOwedPageGrantsTheKeptAsk() {
        let (hosting, commit, frame) = shownPage()
        var grants = 0
        hosting.pageAppeared(windowInWindow: false) { grants += 1 }
        fake.accepts = false
        frame()
        commit()
        commit()
        fake.accepts = true
        hosting.resizeMotion(active: true)
        hosting.trackerDidRead()
        #expect(hosting.isDetached && grants == 0, "mid-motion the page stays detached")
        hosting.resizeMotion(active: false)
        #expect(!hosting.isDetached)
        commit()
        #expect(grants == 1)
    }

    /// The window closed in the hold: its scheduler lets the one-tick client go with no tick. The drop counts as the
    /// frame: the page attaches after that pass's commit with no focus ask (#37175 gap: it stayed detached until the
    /// next ask or window change). The hold ends with no grant: a closed window's page must not take the keys (SetFocus
    /// orders its window front); the tab keeps its ask for the next show.
    @Test func aHoldWhoseFrameTickWasDroppedAttachesWithNoAskAndNoGrant() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: .borderless,
                              backing: .buffered, defer: true)
        defer { window.closeAfterTest() }
        window.contentView?.addSubview(view)
        var blocks: [@MainActor @Sendable () -> Void] = []
        var committed: [@MainActor @Sendable () -> Void] = []
        let commit = {
            let pass = committed
            committed.removeAll()
            for block in pass { block() }
        }
        let hosting = CEFLayerHosting(isEnabled: { true }, schedule: { blocks.append($0) },
                                      makePage: { CEFHostedPageView(frame: $0, makeLayerHost: { _ in CALayer() }) },
                                      holdsFocus: { false }, afterCommit: { committed.append($0) })
        hosting.view = view
        hosting.pageWindowCreated(browser: 4, fork: fake.fork)
        for block in blocks { block() }
        var grants = 0
        hosting.pageAppeared(windowInWindow: false) { grants += 1 }
        #expect(calls == ["4:detach"])
        FrameScheduler.forWindow(window).invalidate()
        commit()
        #expect(calls == ["4:detach", "4:attach"], "the drop attaches with no ask")
        commit()
        #expect(grants == 0 && hosting.firstFrameHold == .none, "no grant into a closed window")
    }

    // MARK: A page the person reaches is never left detached (Aziz 2026-11-10)

    /// Aziz 2026-11-10 (nightly 4269066450801): several browser tabs showed their page but took no click or scroll until
    /// he closed and reopened the window. A motion whose end never reached the page (its container's share lost on the
    /// way) left the window detached at rest; only a window change attached it. A press or a scroll on the page area
    /// now attaches it at once, and the motion's late end, if it ever comes, changes nothing.
    @Test func aPressOnAPageLeftDetachedByALostMotionEndAttachesIt() {
        let hosting = hostedPage()
        hosting.resizeMotion(active: true)
        #expect(hosting.isDetached, "the motion detached it; its end never comes")
        #expect(hosting.personReachedPage(), "the press attaches the page window")
        #expect(!hosting.isDetached && !hosting.inResizeMotion)
        #expect(calls == ["4:detach", "4:attach"])
        hosting.resizeMotion(active: false)
        #expect(calls.count == 2, "a late end is ignored: no motion is counted any more")
        #expect(!hosting.personReachedPage(), "an attached page makes no fork call on a press")
        #expect(calls.count == 2)
    }

    /// A first-frame hold whose frame never came (no tick, no drop) kept the page detached at rest with its focus ask:
    /// a press attaches it, and the kept ask is granted after the next commit, once the fork ordered the window in.
    @Test func aPressOnAPageWhoseFirstFrameNeverCameAttachesItAndGrantsTheKeptAsk() {
        let (hosting, commit, _) = shownPage()
        var grants = 0
        hosting.pageAppeared(windowInWindow: false) { grants += 1 }
        #expect(hosting.isDetached && hosting.holdsFirstFrame())
        #expect(hosting.personReachedPage())
        #expect(!hosting.isDetached && !hosting.holdsFirstFrame())
        #expect(grants == 0, "the window is ordered in at the fork's next observer")
        commit()
        #expect(grants == 1)
    }
}
