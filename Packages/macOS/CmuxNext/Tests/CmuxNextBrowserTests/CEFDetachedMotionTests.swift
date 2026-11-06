import AppKit
@testable import CmuxNextBrowser
import CmuxNextTestSupport
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

    /// A hosted page whose blocks after the commit the test runs (``CEFLayerHosting/pageAppeared(windowInWindow:then:)``).
    func shownPage() -> (CEFLayerHosting, commit: @MainActor () -> Void) {
        var blocks: [@MainActor @Sendable () -> Void] = []
        var committed: [@MainActor @Sendable () -> Void] = []
        let hosting = CEFLayerHosting(isEnabled: { true }, schedule: { blocks.append($0) },
                                      makePage: { CEFHostedPageView(frame: $0, makeLayerHost: { _ in CALayer() }) },
                                      holdsFocus: { false }, afterCommit: { committed.append($0) })
        hosting.view = view
        hosting.pageWindowCreated(browser: 4, fork: fake.fork)
        for block in blocks { block() }
        #expect(hosting.page != nil)
        return (hosting, {
            let pass = committed
            committed.removeAll()
            for block in pass { block() }
        })
    }

    /// Cmd-N's page shows in the key's turn with its window out of the window: detached in that turn (no window order
    /// before the first frame), attached after its commit, and the focus grant comes one pass later, after the fork's
    /// order-in. A grant asked meanwhile waits.
    @Test func aPageShownWithItsWindowOutAttachesAfterTheCommitAndGrantsAfterTheAttach() {
        let (hosting, commit) = shownPage()
        var grants = 0
        hosting.pageAppeared(windowInWindow: false) { grants += 1 }
        #expect(calls == ["4:detach"])
        #expect(hosting.pageTakesFocus(), "no window to make key in the turn it showed")
        commit()
        #expect(calls == ["4:detach", "4:attach"])
        #expect(grants == 0, "the fork orders the window in at its next observer")
        #expect(hosting.pageTakesFocus())
        commit()
        #expect(grants == 1)
        #expect(!hosting.pageTakesFocus() && !hosting.isDetached && hosting.firstFrameHold == .none)
    }

    /// A page whose window is already in the window (a tab switch inside its pane) is left alone.
    @Test func aPageShownWithItsWindowInIsLeftAlone() {
        let (hosting, commit) = shownPage()
        var grants = 0
        hosting.pageAppeared(windowInWindow: true) { grants += 1 }
        commit()
        #expect(calls.isEmpty && grants == 0 && hosting.firstFrameHold == .none)
    }

    /// A motion that began before the commit owns the detached page: no attach at the commit, one at the landing.
    @Test func aMotionStartedInTheShowTurnAttachesOnlyAtItsLanding() {
        let (hosting, commit) = shownPage()
        var grants = 0
        hosting.pageAppeared(windowInWindow: false) { grants += 1 }
        hosting.resizeMotion(active: true)
        commit()
        #expect(calls == ["4:detach"] && grants == 1 && hosting.isDetached)
        hosting.resizeMotion(active: false)
        #expect(calls == ["4:detach", "4:attach"])
    }

    /// The page window closed before the commit: nothing reaches the fork for it after.
    @Test func aPageWindowClosedBeforeTheCommitIsNotAttached() {
        let (hosting, commit) = shownPage()
        hosting.pageAppeared(windowInWindow: false) {}
        hosting.stop()
        commit()
        commit()
        #expect(calls == ["4:detach"] && hosting.firstFrameHold == .none)
    }
}
