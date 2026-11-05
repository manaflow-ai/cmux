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
}
