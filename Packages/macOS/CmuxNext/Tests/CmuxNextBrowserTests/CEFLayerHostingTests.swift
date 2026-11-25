import AppKit
@testable import CmuxNextBrowser
import CmuxNextTestSupport
import CmuxNextWakeupsTestSupport
import Testing

/// Layer hosting (fork API 26) of a page window, without Chromium: a fake fork call, a run-loop
/// turn the test ends itself, and the host view in a real window for the hosted-page count.
/// Review 1 of PL-cef-layer slice 1: the first page of a new pane stayed on its child window when
/// the fork refused inside Chromium's creation stack; every tab switch called the fork; a closed
/// hosted view stayed counted in `debug.cef`; a context nothing could show left the page blank.
@MainActor
@Suite(.closesItsWindows) struct CEFLayerHostingTests {
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
        // A pane deadline of its own (8 ms): with S5 on by default the tunable reads 0 (`CEFLayerHosting.waitMs`).
        let hosting = CEFLayerHosting(isEnabled: enabled, schedule: { turn.add($0) },
                                      makePage: { CEFHostedPageView(frame: $0, makeLayerHost: layerHost) },
                                      resizeDeadlineMs: { 8 })
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
        defer { window.closeAfterTest() }
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

    /// Resize sync (fork API 27) with a deadline set (`browserResize.syncDeadline` above 0): a hosted page holds the
    /// window's commit for its frame at a new size up to the deadline, so it resizes in its pane's frame; a page back
    /// in its own window never holds it (Chromium's 500 ms wait made every page resize stall a cmux frame).
    @Test func aHostedPageWaitsForItsResizeFrameAndAnUnhostedOneNever() {
        var enabled = true
        let turn = turn
        let hosting = CEFLayerHosting(isEnabled: { enabled }, schedule: { turn.add($0) },
                                      makePage: { CEFHostedPageView(frame: $0, makeLayerHost: { _ in CALayer() }) },
                                      resizeDeadlineMs: { 8 })
        hosting.view = view
        hosting.pageWindowCreated(browser: 3, fork: fake.fork)
        turn.end()
        #expect(fake.syncs.map { $0.browser } == [3])
        #expect(fake.syncs.first.map { $0.timeoutMs > 0 } == true)
        enabled = false
        hosting.pageShown(browser: 3)
        #expect(fake.syncs.last.map { $0.timeoutMs } == 0)
    }

    /// cmux-ad m18/m19: a pane never waits for a page, so the deadline is 0 by default. A page that waits for nothing
    /// asks the fork for nothing: no resize-sync call when it is hosted, shown or given back its window.
    @Test func aZeroDeadlineMakesNoForkCall() {
        var enabled = true
        let turn = turn
        let hosting = CEFLayerHosting(isEnabled: { enabled }, schedule: { turn.add($0) },
                                      makePage: { CEFHostedPageView(frame: $0, makeLayerHost: { _ in CALayer() }) },
                                      resizeDeadlineMs: { 0 })
        hosting.view = view
        hosting.pageWindowCreated(browser: 3, fork: fake.fork)
        turn.end()
        #expect(hosting.page != nil)
        enabled = false
        hosting.pageShown(browser: 3)
        #expect(fake.syncs.isEmpty, "a 0 deadline sent \(fake.syncs.count) resize-sync calls")
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
@Suite(.closesItsWindows) struct CEFLayerHostingLiveResizeTests {
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
        defer { still.closeAfterTest() }
        still.contentView?.addSubview(view)
        hosting.windowDidChange()
        #expect(fake.syncs.map(\.timeoutMs) == [50, 0])
        // It joins a window in its live resize: it gets that resize's wait, and the window's end takes it back.
        view.removeFromSuperview()
        hosting.windowDidChange()
        let resizing = LiveResizeWindow.make(live: true)
        defer { resizing.closeAfterTest() }
        resizing.contentView?.addSubview(view)
        hosting.windowDidChange()
        #expect(fake.syncs.map(\.timeoutMs) == [50, 0, 50])
        hosting.windowLiveResize(active: false)
        #expect(fake.syncs.map(\.timeoutMs) == [50, 0, 50, 0])
    }
}

/// cmux#26037: a page beside a dragged divider trailed it by some frames (Chromium draws in another process, and
/// from fork API 27 a page window never waits for its frame at a new size unless asked). With `dragResize` at
/// `resizeSync` every page over the dragged pane, hosted or not, waits for its frame up to the drag deadline from the
/// drag's first move until its release landed, capped at half the shortest display frame so no app frame is held
/// past its display link's target time.
@MainActor
@Suite(.closesItsWindows) struct CEFLayerHostingPaneDragTests {
    let fake = CEFLayerHostingTests.FakeFork()
    let view = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))

    func makeHosting(enabled: Bool, refreshIntervals: [Double] = []) -> CEFLayerHosting {
        let hosting = CEFLayerHosting(isEnabled: { enabled }, schedule: { $0() },
                                      makePage: { CEFHostedPageView(frame: $0, makeLayerHost: { _ in CALayer() }) },
                                      resizeDeadlineMs: { 8 }, liveResizeDeadlineMs: { 50 }, dragResizeDeadlineMs: { 30 },
                                      refreshIntervals: { refreshIntervals })
        hosting.view = view
        return hosting
    }

    @Test func aPageWindowThatIsNotHostedWaitsForTheDragOnly() {
        let hosting = makeHosting(enabled: false)
        hosting.pageWindowCreated(browser: 4, fork: fake.fork)
        hosting.paneResizeDrag(active: true)
        #expect(hosting.inPaneDrag)
        hosting.paneResizeDrag(active: false)
        #expect(!hosting.inPaneDrag)
        #expect(fake.syncs.map(\.browser) == [4, 4])
        #expect(fake.syncs.map(\.timeoutMs) == [30, 0])
    }

    @Test func aHostedPageGoesBackToItsPaneDeadlineWhenTheDragLands() {
        let hosting = makeHosting(enabled: true)
        hosting.pageWindowCreated(browser: 5, fork: fake.fork)
        hosting.paneResizeDrag(active: true)
        hosting.paneResizeDrag(active: false)
        #expect(fake.syncs.map(\.timeoutMs) == [8, 30, 8])
    }

    /// Every tab container of the pane shares the page window and tells its own start and end: the wait lasts
    /// until the last one ended (a parked container's early end does not cut the shown one's landing short).
    @Test func theDragLastsUntilTheLastContainerEnded() {
        let hosting = makeHosting(enabled: false)
        hosting.pageWindowCreated(browser: 4, fork: fake.fork)
        hosting.paneResizeDrag(active: true)
        hosting.paneResizeDrag(active: true)
        hosting.paneResizeDrag(active: false)
        #expect(hosting.inPaneDrag)
        #expect(fake.syncs.map(\.timeoutMs) == [30])
        hosting.paneResizeDrag(active: false)
        hosting.paneResizeDrag(active: false)
        #expect(!hosting.inPaneDrag, "an end with no start is ignored")
        #expect(fake.syncs.map(\.timeoutMs) == [30, 0])
    }

    /// Review 1 of cmux#26037: a pane's only tab closed mid-drag; its container never heard the end, and the next
    /// page window of the pane took the drag's wait for every later resize. A closed page window ends it.
    @Test func aClosedPageWindowDoesNotPassTheDragsWaitToTheNextOne() {
        let hosting = makeHosting(enabled: false)
        hosting.pageWindowCreated(browser: 4, fork: fake.fork)
        hosting.paneResizeDrag(active: true)
        hosting.stop()
        hosting.pageWindowCreated(browser: 9, fork: fake.fork)
        #expect(!hosting.inPaneDrag)
        #expect(fake.syncs.map(\.browser) == [4, 4])
        #expect(fake.syncs.map(\.timeoutMs) == [30, 0])
        hosting.paneResizeDrag(active: false)
        #expect(fake.syncs.count == 2, "the closed tab's late end changes nothing")
    }

    /// The wait never passes half the shortest display frame: 4 ms once a display runs at 120 Hz.
    @Test func theDragWaitIsCappedAtHalfTheShortestDisplayFrame() {
        let hosting = makeHosting(enabled: false, refreshIntervals: [1.0 / 60, 1.0 / 120])
        hosting.pageWindowCreated(browser: 4, fork: fake.fork)
        hosting.paneResizeDrag(active: true)
        #expect(fake.syncs.map(\.timeoutMs) == [4])
    }

    /// The window's own live resize wins while both run, and the drag's wait comes back after it.
    @Test func aLiveResizeDuringTheDragKeepsItsOwnDeadline() {
        let hosting = makeHosting(enabled: false)
        hosting.pageWindowCreated(browser: 4, fork: fake.fork)
        hosting.paneResizeDrag(active: true)
        hosting.windowLiveResize(active: true)
        hosting.windowLiveResize(active: false)
        hosting.paneResizeDrag(active: false)
        #expect(fake.syncs.map(\.timeoutMs) == [30, 50, 30, 0])
    }

    /// A page window made during the drag (a pane's first page) starts with the drag's wait.
    @Test func aPageWindowMadeDuringTheDragWaits() {
        let hosting = makeHosting(enabled: false)
        hosting.paneResizeDrag(active: true)
        #expect(fake.syncs.isEmpty, "no page window, no fork call")
        hosting.pageWindowCreated(browser: 6, fork: fake.fork)
        #expect(fake.syncs.map(\.timeoutMs) == [30])
    }

    /// Below fork API 27 there is no resize sync call: the page lays out live and nothing else changes.
    @Test func belowForkAPI27NothingReachesTheFork() {
        let hosting = makeHosting(enabled: false)
        hosting.pageWindowCreated(browser: 4, fork: CEFLayerHosting.Fork(setLayerHosting: { _, _ in 0 }))
        hosting.paneResizeDrag(active: true)
        hosting.paneResizeDrag(active: false)
        #expect(fake.syncs.isEmpty)
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

/// Window frame sync (fork API 32, hq#11877): in a page sync (S5: a drag, a key resize, a pane spring) every resize of a
/// hosted page's view hands the fork the window's Core Animation fence for this turn, one fence per window per turn,
/// and the main thread never waits for it. Outside a page sync, or with the page in its own window, no fence is asked.
/// The fence here is a port of the test's own (its receive right kept, so its send rights can be counted).
@MainActor
@Suite(.closesItsWindows) struct CEFResizeFenceWiringTests {
    final class FenceFork {
        private(set) var fences: [(browser: Int32, port: mach_port_t, timeoutMs: Int32)] = []
        var dones: [@MainActor (Bool) -> Void] = []
        var takes = true
        var fork: CEFLayerHosting.Fork {
            CEFLayerHosting.Fork(setLayerHosting: { _, enabled in enabled ? 7 : 0 },
                                 resizeFence: { [self] browser, port, timeout, done in
                                     guard takes else { return false }
                                     fences.append((browser, port, timeout))
                                     dones.append(done)
                                     return true
                                 })
        }
    }

    let fork = FenceFork()
    let clock = ManualClock()
    /// The fences made, as receive rights this test keeps (so the app's send rights on them can be counted).
    final class Ports {
        var made: [mach_port_t] = []
        func make() -> mach_port_t? {
            var name = mach_port_t(MACH_PORT_NULL)
            guard mach_port_allocate(mach_task_self_, MACH_PORT_RIGHT_RECEIVE, &name) == KERN_SUCCESS,
                  mach_port_insert_right(mach_task_self_, name, name, mach_msg_type_name_t(MACH_MSG_TYPE_MAKE_SEND))
                  == KERN_SUCCESS else { return nil }
            made.append(name)
            return name
        }
    }

    let ports = Ports()

    /// The send rights of `port` this process holds (the app's own, as the fake fork takes none).
    func sendRights(_ port: mach_port_t) -> mach_port_urefs_t {
        var refs: mach_port_urefs_t = 0
        _ = mach_port_get_refs(mach_task_self_, port, MACH_PORT_RIGHT_SEND, &refs)
        return refs
    }

    func makeHosted(_ enabled: Bool = true) -> (CEFLayerHosting, NSView, NSWindow) {
        let window = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 400, height: 300),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        view.wantsLayer = true
        window.contentView?.wantsLayer = true
        window.contentView?.addSubview(view)
        let ports = ports
        let hosting = CEFLayerHosting(isEnabled: { enabled }, schedule: { $0() },
                                      makePage: { CEFHostedPageView(frame: $0, makeLayerHost: { _ in CALayer() }) },
                                      refreshIntervals: { [1.0 / 60] },
                                      resizeFences: CEFResizeFences(clock: clock, makePort: { _ in ports.make() }))
        hosting.view = view
        hosting.pageWindowCreated(browser: 3, fork: fork.fork)
        return (hosting, view, window)
    }

    /// Runs the blocks queued for the end of this turn (``CEFLayerHosting/atEndOfTurn(_:)``).
    func endTurn() { CFRunLoopRunInMode(.defaultMode, 0.005, false) }

    @Test func aResizeOutsideAPageSyncAsksNoFence() {
        let (hosting, _, window) = makeHosted()
        defer { window.close() }
        #expect(hosting.page != nil)
        hosting.pageViewResized()
        #expect(fork.fences.isEmpty)
        #expect(ports.made.isEmpty)
    }

    @Test func aPageInItsOwnWindowAsksNoFence() {
        let (hosting, _, window) = makeHosted(false)
        defer { window.close() }
        hosting.paneResizeDrag(active: true)
        hosting.pageViewResized()
        #expect(fork.fences.isEmpty)
    }

    @Test func pagesResizedInOneTurnShareOneFenceWithAOneRefreshDeadline() throws {
        let (hosting, _, window) = makeHosted()
        defer { window.close() }
        hosting.paneResizeDrag(active: true)
        let before = CEFHostView.trackerStats.resizeFences
        hosting.pageViewResized()
        hosting.pageViewResized()
        let first = try #require(fork.fences.first)
        #expect(fork.fences.count == 2)
        #expect(ports.made == [first.port])
        #expect(fork.fences.allSatisfy { $0.browser == 3 && $0.port == first.port })
        #expect(first.timeoutMs == 17)
        #expect(CEFHostView.trackerStats.resizeFences == before + 1)
        let presented = CEFHostView.trackerStats.resizeFencePresented
        for done in fork.dones { done(true) }
        #expect(CEFHostView.trackerStats.resizeFencePresented == presented + 2)
        // Every page reported, but the turn is not over: another page may still join.
        #expect(sendRights(first.port) == 1)
        endTurn()
        #expect(sendRights(first.port) == 0)
    }

    /// A layout change that shows in one commit (a zoom) announced the page's resize: each resize of the view in the
    /// turn that shows it joins the window's fence, with the GPU's deadline at the commit's bound of refreshes (4 at
    /// 60 Hz: 67 ms), and a resize in a later turn joins none. A change taken back before it showed owes none.
    @Test func aResizeThatAPaneCommitAnnouncedJoinsTheFenceForItsTurnOnly() throws {
        let (hosting, _, window) = makeHosted()
        defer { window.close() }
        hosting.paneCommitWillResize(true)
        hosting.pageViewResized()
        hosting.pageViewResized()
        let first = try #require(fork.fences.first, "the resize that shows a zoom joined no fence")
        #expect(fork.fences.count == 2)
        #expect(first.timeoutMs == 67)
        for done in fork.dones { done(true) }
        endTurn()
        #expect(!hosting.commitResizeOwed)
        hosting.pageViewResized()
        #expect(fork.fences.count == 2, "a resize after the commit's turn joined a fence")

        hosting.paneCommitWillResize(true)
        hosting.paneCommitWillResize(false)
        hosting.pageViewResized()
        #expect(fork.fences.count == 2, "a resize of a change taken back joined a fence")
    }

    /// A zoom's resize joins the window's fence only for a hosted page on an engine with the fence (fork API 34); on
    /// another engine, or with the page in its own window, the page takes the zoomed size ahead of the commit instead
    /// (`CEFTabContentView+PaneCommit`).
    @Test func onlyAHostedPageOnAnEngineWithTheFenceJoinsIt() {
        let (hosting, view, window) = makeHosted()
        defer { window.close() }
        #expect(hosting.joinsResizeFence)
        let fenceless = CEFLayerHosting(schedule: { $0() },
                                        makePage: { CEFHostedPageView(frame: $0, makeLayerHost: { _ in CALayer() }) },
                                        refreshIntervals: { [1.0 / 60] },
                                        resizeFences: CEFResizeFences(clock: clock, makePort: { _ in nil }))
        fenceless.view = view
        fenceless.pageWindowCreated(browser: 4, fork: CEFLayerHosting.Fork(setLayerHosting: { _, enabled in enabled ? 8 : 0 }))
        #expect(fenceless.page != nil)
        #expect(!fenceless.joinsResizeFence, "a page on an engine with no fence joins one")
        fenceless.stop()
        let (unhosted, _, other) = makeHosted(false)
        defer { other.close() }
        #expect(unhosted.page == nil)
        #expect(!unhosted.joinsResizeFence, "a page in its own window joins the window's fence")
    }

    /// A resize that joins a fence counts its main-thread time (`fence_join_ms` in `debug.cef`), for the perf-hot
    /// budget of ``CEFLayerHosting/pageViewResized()``; a resize that joins none counts none.
    @Test func aResizeThatJoinsAFenceCountsItsTime() throws {
        let (hosting, _, window) = makeHosted()
        defer { window.close() }
        let before = CEFHostView.trackerStats.resizeFenceJoinSeconds
        hosting.pageViewResized()
        #expect(CEFHostView.trackerStats.resizeFenceJoinSeconds == before, "a resize outside a page sync counted fence time")
        hosting.paneResizeDrag(active: true)
        hosting.pageViewResized()
        #expect(CEFHostView.trackerStats.resizeFenceJoinSeconds > before, "a resize that joined a fence counted no time")
        #expect(CEFHostView.trackerStats.reportFields["fence_join_ms"] != nil)
        for done in fork.dones { done(true) }
        endTurn()
    }

    /// After its turn, a fence with a page still out keeps its send right until that page reports, then lets it go: a
    /// fence freed with its right would hold the window's commits for good, and one kept past `done` would too.
    @Test func aFenceOutlivesItsTurnUntilItsPagesReport() throws {
        let (hosting, _, window) = makeHosted()
        defer { window.close() }
        hosting.paneResizeDrag(active: true)
        hosting.pageViewResized()
        let fence = try #require(fork.fences.first)
        endTurn()
        #expect(sendRights(fence.port) == 1)
        for done in fork.dones { done(true) }
        #expect(sendRights(fence.port) == 0)
    }

    /// A page that missed its frame at a new size joins no more fences in that drag, so a page slower than the display
    /// never holds the window's commits frame after frame; the next drag starts in sync again. A page that keeps up
    /// joins at every resize (Leo, 2026-11-18, of a divider drag beside a long chat: "we SLOW :(").
    @Test func aPageThatMissesJoinsNoMoreFencesInThatDrag() {
        let (hosting, _, window) = makeHosted()
        defer { window.close() }
        hosting.paneResizeDrag(active: true)
        hosting.pageViewResized()
        fork.dones.last?(true)
        endTurn()
        hosting.pageViewResized()
        #expect(fork.fences.count == 2)
        fork.dones.last?(false)
        endTurn()
        hosting.pageViewResized()
        hosting.pageViewResized()
        #expect(fork.fences.count == 2)
        hosting.paneResizeDrag(active: false)
        hosting.paneResizeDrag(active: true)
        hosting.pageViewResized()
        #expect(fork.fences.count == 3)
        fork.dones.last?(true)
        endTurn()
    }

    /// A page that never reports holds the window no longer than this app's deadline (the fork's and one refresh).
    @Test func aFenceGoesAtItsDeadline() async throws {
        let (hosting, _, window) = makeHosted()
        defer { window.close() }
        hosting.paneResizeDrag(active: true)
        hosting.pageViewResized()
        let fence = try #require(fork.fences.first)
        endTurn()
        let expired = CEFHostView.trackerStats.resizeFencesExpired
        try await clock.waitForSleeper()
        clock.advance(by: .milliseconds(40))
        for _ in 0..<50 where sendRights(fence.port) != 0 { await Task.yield() }
        #expect(sendRights(fence.port) == 0)
        #expect(CEFHostView.trackerStats.resizeFencesExpired == expired + 1)
        // A late report finds the right gone and changes nothing.
        for done in fork.dones { done(false) }
        #expect(sendRights(fence.port) == 0)
    }

    /// A fence no page joined goes at the end of its turn.
    @Test func aFenceNoPageJoinedGoesWithItsTurn() throws {
        let (hosting, _, window) = makeHosted()
        defer { window.close() }
        fork.takes = false
        hosting.paneResizeDrag(active: true)
        hosting.pageViewResized()
        let port = try #require(ports.made.first)
        #expect(sendRights(port) == 1)
        endTurn()
        #expect(sendRights(port) == 0)
    }
}
