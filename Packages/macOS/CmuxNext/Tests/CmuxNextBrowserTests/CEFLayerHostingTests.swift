import AppKit
@testable import CmuxNextBrowser
import Testing

/// Layer hosting (fork API 26) of a page window, without Chromium: a fake fork call, a run-loop
/// turn the test ends itself, and the host view in a real window for the hosted-page count.
/// Review 1 of PL-cef-layer slice 1: the first page of a new pane stayed on its child window when
/// the fork refused inside Chromium's creation stack; every tab switch called the fork; a closed
/// hosted view stayed counted in `debug.cef`; a context nothing could show left the page blank.
@MainActor
@Suite struct CEFLayerHostingTests {
    /// The fork side: the context id it gives (0 refuses) and every call.
    final class FakeFork {
        var contextID: UInt32 = 7
        private(set) var calls: [(browser: Int32, enabled: Bool)] = []
        /// `cmux_browser_set_resize_sync` calls (fork API 27).
        private(set) var syncs: [(browser: Int32, timeoutMs: Int32)] = []
        /// Whether `cmux_browser_set_resize_sync` takes the value (false: a closed browser's id).
        var syncAccepts = true
        var fork: CEFLayerHosting.Fork {
            CEFLayerHosting.Fork(setLayerHosting: { [self] browser, enabled in
                calls.append((browser, enabled))
                return enabled ? contextID : 0
            }, setResizeSync: { [self] browser, timeout in
                syncs.append((browser, timeout))
                return syncAccepts
            })
        }
    }

    /// Blocks waiting for the end of the run-loop turn.
    final class Turn {
        private var blocks: [@MainActor @Sendable () -> Void] = []
        var isEmpty: Bool { blocks.isEmpty }
        func add(_ block: @escaping @MainActor @Sendable () -> Void) { blocks.append(block) }
        func end() {
            let due = blocks
            blocks = []
            for block in due { block() }
        }
    }

    let fake = FakeFork()
    let turn = Turn()
    let view = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))

    func makeHosting(enabled: @escaping () -> Bool = { true },
                     layerHost: @escaping (UInt32) -> CALayer? = { _ in CALayer() }) -> CEFLayerHosting {
        let turn = turn
        let hosting = CEFLayerHosting(isEnabled: enabled, schedule: { turn.add($0) },
                                      makePage: { CEFHostedPageView(frame: $0, makeLayerHost: layerHost) })
        hosting.view = view
        return hosting
    }

    @Test func aNewPageWindowAsksAfterChromiumsCreationStackReturned() throws {
        let hosting = makeHosting()
        hosting.pageWindowCreated(browser: 3, fork: fake.fork)
        // Inside OnAfterCreated Chromium has not put the page in its window yet.
        #expect(fake.calls.isEmpty)
        turn.end()
        #expect(fake.calls.map { $0.browser } == [3])
        #expect(fake.calls.map { $0.enabled } == [true])
        let page = try #require(hosting.page)
        #expect(page.contextID == 7)
        #expect(view.subviews.first === page)
    }

    @Test func aTabSwitchInAHostedPaneMakesNoForkCall() {
        let hosting = makeHosting()
        hosting.pageWindowCreated(browser: 3, fork: fake.fork)
        turn.end()
        for browser: Int32 in [4, 5, 3, 4] { hosting.pageShown(browser: browser) }
        #expect(fake.calls.count == 1)
        #expect(hosting.forkCalls == 1)
        #expect(hosting.page?.contextID == 7)
    }

    @Test func aRefusalAtCreationRetriesAtTheTrackersNextRead() throws {
        let hosting = makeHosting()
        let refusedBefore = CEFHostView.trackerStats.hostingRefused
        fake.contextID = 0
        hosting.pageWindowCreated(browser: 3, fork: fake.fork)
        turn.end()
        #expect(hosting.page == nil)
        #expect(hosting.isRetryArmed)
        #expect(hosting.refusals == 1)
        #expect(CEFHostView.trackerStats.hostingRefused == refusedBefore + 1)
        // The tracker attached to the page window: its read is the signal; the request
        // still waits for the end of that turn (the read is inside the fork's update).
        fake.contextID = 9
        hosting.trackerDidRead()
        #expect(fake.calls.count == 1)
        turn.end()
        #expect(fake.calls.count == 2)
        #expect(try #require(hosting.page).contextID == 9)
        #expect(!hosting.isRetryArmed)
    }

    @Test func aSecondRefusalWaitsForTheNextShow() throws {
        let hosting = makeHosting()
        fake.contextID = 0
        hosting.pageWindowCreated(browser: 3, fork: fake.fork)
        turn.end()
        hosting.trackerDidRead()
        turn.end()
        #expect(fake.calls.count == 2)
        #expect(!hosting.isRetryArmed)
        // Tracker reads come several times per frame while a pane moves: none asks again.
        for _ in 0..<5 { hosting.trackerDidRead() }
        #expect(turn.isEmpty)
        fake.contextID = 11
        hosting.pageShown(browser: 3)
        #expect(fake.calls.count == 3)
        #expect(try #require(hosting.page).contextID == 11)
    }

    @Test func hostingOffInTheTunableGivesThePageItsWindowBackAtTheNextShow() {
        var on = true
        let hosting = makeHosting(enabled: { on })
        hosting.pageWindowCreated(browser: 3, fork: fake.fork)
        turn.end()
        #expect(hosting.page != nil)
        on = false
        hosting.pageShown(browser: 4)
        #expect(fake.calls.last?.browser == 4)
        #expect(fake.calls.last?.enabled == false)
        #expect(hosting.page == nil)
        #expect(view.subviews.isEmpty)
        hosting.pageShown(browser: 4)
        #expect(fake.calls.count == 2)
        on = true
        hosting.pageShown(browser: 4)
        #expect(fake.calls.count == 3)
        #expect(hosting.page != nil)
    }

    @Test func withTheTunableOffOrBelowForkAPI26NothingReachesTheFork() {
        let off = makeHosting(enabled: { false })
        off.pageWindowCreated(browser: 3, fork: fake.fork)
        #expect(turn.isEmpty)
        off.pageShown(browser: 3)
        off.trackerDidRead()
        #expect(fake.calls.isEmpty)

        #expect(CEFLayerHosting.Fork(shim: nil, apiVersion: 30) == nil)
        let old = makeHosting()
        old.pageWindowCreated(browser: 3, fork: nil)
        old.pageShown(browser: 3)
        #expect(turn.isEmpty)
        #expect(old.page == nil)
        #expect(old.forkCalls == 0)
    }

    @Test func aNewPageWindowDropsTheOldWindowsContext() throws {
        let hosting = makeHosting()
        hosting.pageWindowCreated(browser: 3, fork: fake.fork)
        turn.end()
        fake.contextID = 8
        hosting.pageWindowCreated(browser: 12, fork: fake.fork)
        // The old context went with its window: nothing shows it until the new one comes.
        #expect(hosting.page == nil)
        turn.end()
        #expect(fake.calls.last?.browser == 12)
        #expect(try #require(hosting.page).contextID == 8)
        #expect(view.subviews.count == 1)
    }

    @Test func aContextNothingCanShowGivesThePageItsWindowBack() {
        let hosting = makeHosting(layerHost: { _ in nil })
        hosting.pageWindowCreated(browser: 3, fork: fake.fork)
        turn.end()
        #expect(fake.calls.map { $0.enabled } == [true, false])
        #expect(hosting.page == nil)
        #expect(view.subviews.isEmpty)
        #expect(hosting.refusals == 1)
        // Not the fork's refusal: a retry would fail the same way.
        #expect(!hosting.isRetryArmed)
    }

    @Test func hostedPagesCountsHostedViewsInAWindowOnly() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: .borderless,
                              backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let container = NSView(frame: window.contentRect(forFrameRect: window.frame))
        window.contentView = container
        container.addSubview(view)
        let before = CEFHostView.trackerStats.hostedPages

        let pane = makeHosting()
        pane.pageWindowCreated(browser: 3, fork: fake.fork)
        turn.end()
        #expect(CEFHostView.trackerStats.hostedPages == before + 1)
        // DevTools closed / page window closed: hosting off for the browser, the count back.
        pane.stop()
        #expect(fake.calls.last?.browser == 3)
        #expect(fake.calls.last?.enabled == false)
        #expect(CEFHostView.trackerStats.hostedPages == before)

        pane.pageWindowCreated(browser: 4, fork: fake.fork)
        turn.end()
        #expect(CEFHostView.trackerStats.hostedPages == before + 1)
        // A host view released while it hosts (its pane closed) takes its count with it.
        view.removeFromSuperview()
        #expect(CEFHostView.trackerStats.hostedPages == before)
    }

    /// The SPI the hosted view needs, on the macOS this runs on (14, 15, 26, 27).
    @Test func theSystemsLayerHostTakesAContextID() throws {
        let layer = try #require(CEFHostedPageView.layerHost(contextID: 5))
        #expect((layer.value(forKey: "contextId") as? NSNumber)?.uint32Value == 5)
        let page = CEFHostedPageView(frame: NSRect(x: 0, y: 0, width: 10, height: 10))
        #expect(page.host(contextID: 5))
        #expect(page.contextID == 5)
        #expect(page.host(contextID: 0))
        #expect(page.contextID == 0)
    }

    /// Resize sync (fork API 27): a hosted page holds the window's commit for its frame at a new
    /// size up to the deadline, so it resizes in its pane's frame; a page back in its own window
    /// never holds it (Chromium's 500 ms wait made every page resize stall a cmux frame).
    @Test func aHostedPageWaitsForItsResizeFrameAndAnUnhostedOneNever() {
        var enabled = true
        let hosting = makeHosting(enabled: { enabled })
        hosting.pageWindowCreated(browser: 3, fork: fake.fork)
        turn.end()
        #expect(fake.syncs.map { $0.browser } == [3])
        #expect(fake.syncs.first.map { $0.timeoutMs > 0 } == true)
        enabled = false
        hosting.pageShown(browser: 3)
        #expect(fake.syncs.last.map { $0.timeoutMs } == 0)
    }

    @Test func aRefusedPageNeverAsksToHoldTheCommit() {
        let hosting = makeHosting()
        fake.contextID = 0
        hosting.pageWindowCreated(browser: 3, fork: fake.fork)
        turn.end()
        #expect(fake.syncs.isEmpty)
    }
}

/// Review 1 of the fork (finding 3): with fork API 27 pinned an embedded page never waits for its frame at the new
/// size, so a page that is not layer hosted lagged its pane during the window's live resize, which Chromium had kept
/// in sync. The window's live resize gives every page over the view a bounded wait for that time.
@MainActor
@Suite struct CEFLayerHostingLiveResizeTests {
    let fake = CEFLayerHostingTests.FakeFork()
    let view = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))

    func makeHosting(enabled: Bool) -> CEFLayerHosting {
        let hosting = CEFLayerHosting(isEnabled: { enabled }, schedule: { $0() },
                                      makePage: { CEFHostedPageView(frame: $0, makeLayerHost: { _ in CALayer() }) },
                                      resizeDeadlineMs: { 8 }, liveResizeDeadlineMs: { 50 }, refreshIntervals: { [] })
        hosting.view = view
        return hosting
    }

    @Test func aPageWindowThatIsNotHostedWaitsDuringTheWindowsLiveResizeOnly() {
        let hosting = makeHosting(enabled: false)
        hosting.pageWindowCreated(browser: 4, fork: fake.fork)
        #expect(fake.syncs.isEmpty)
        hosting.windowLiveResize(active: true)
        hosting.windowLiveResize(active: false)
        #expect(fake.syncs.map(\.browser) == [4, 4])
        #expect(fake.syncs.map(\.timeoutMs) == [50, 0])
    }

    @Test func aHostedPageGoesBackToItsPaneDeadlineAfterTheLiveResize() {
        let hosting = makeHosting(enabled: true)
        hosting.pageWindowCreated(browser: 5, fork: fake.fork)
        #expect(fake.syncs.map(\.timeoutMs) == [8])
        hosting.windowLiveResize(active: true)
        hosting.windowLiveResize(active: false)
        #expect(fake.syncs.map(\.timeoutMs) == [8, 50, 8])
    }

    @Test func noPageWindowMeansNoForkCall() {
        let hosting = makeHosting(enabled: true)
        hosting.windowLiveResize(active: true)
        #expect(fake.syncs.isEmpty)
    }

    /// Review 3: AppKit sends `viewWillStartLiveResize` and `viewDidEndLiveResize` only to the views in the window at
    /// that time. A host view that left the window during its live resize (a pane parked, a workspace switched) kept
    /// the live-resize wait after it, so a page that is not hosted held the commit on every later resize; one that
    /// joined a window during its live resize never got the wait.
    @Test func aViewThatChangesWindowsDuringALiveResizeFollowsItsNewWindow() {
        let hosting = makeHosting(enabled: false)
        hosting.pageWindowCreated(browser: 4, fork: fake.fork)
        hosting.windowLiveResize(active: true)
        // The view leaves the resizing window (CEFHostView.viewDidMoveToWindow) and shows later in one that is not resizing.
        hosting.windowDidChange()
        let still = LiveResizeWindow.make(live: false)
        still.contentView?.addSubview(view)
        hosting.windowDidChange()
        #expect(fake.syncs.map(\.timeoutMs) == [50, 0])
        // It joins a window in its live resize: it gets that resize's wait, and the window's end takes it back.
        view.removeFromSuperview()
        hosting.windowDidChange()
        let resizing = LiveResizeWindow.make(live: true)
        resizing.contentView?.addSubview(view)
        hosting.windowDidChange()
        #expect(fake.syncs.map(\.timeoutMs) == [50, 0, 50])
        hosting.windowLiveResize(active: false)
        #expect(fake.syncs.map(\.timeoutMs) == [50, 0, 50, 0])
    }
}

/// A window whose live resize the test sets (`NSWindow.inLiveResize` is true only while the user drags an edge).
private final class LiveResizeWindow: NSWindow {
    var isLive = false
    override var inLiveResize: Bool { isLive }

    static func make(live: Bool) -> LiveResizeWindow {
        let window = LiveResizeWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: .borderless,
                                      backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.isLive = live
        return window
    }
}
