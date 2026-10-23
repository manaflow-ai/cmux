import AppKit
@testable import CmuxNextBrowser
import Testing

/// Layer hosting (fork API 26) of a page window, without Chromium: a fake fork call, a run-loop
/// turn the test ends itself, and the host view in a real window for the hosted-page count.
/// Review 1 of PL-cef-layer slice 1: the first page of a new pane stayed on its child window when
/// the fork refused inside Chromium's creation stack; every tab switch called the fork; a closed
/// hosted view stayed counted in `debug.cef`; a context nothing could show left the page blank.
/// Review 2: a page window the fork refused, or a context nothing could show, still made a fork
/// call on every tab show; a retry and teardown addressed a browser that could be closed (a
/// placeholder, the last tab); a refused docked DevTools never asked again.
@MainActor
@Suite struct CEFLayerHostingTests {
    /// The fork side: the context id it gives (0 refuses) and every call.
    final class FakeFork {
        var contextID: UInt32 = 7
        private(set) var calls: [(browser: Int32, enabled: Bool)] = []
        var fork: CEFLayerHosting.Fork {
            CEFLayerHosting.Fork { [self] browser, enabled in
                calls.append((browser, enabled))
                return enabled ? contextID : 0
            }
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
        fake.contextID = 0
        hosting.pageWindowCreated(browser: 3, fork: fake.fork)
        turn.end()
        #expect(hosting.page == nil)
        #expect(hosting.isRetryArmed)
        #expect(hosting.refusals == 1)
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

    @Test func aWindowTheForkRefusedAfterItsRetryMakesNoCallPerShow() throws {
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
        // Tab shows are the 10 ms tab-switch path: the window's answer stands.
        fake.contextID = 11
        for browser: Int32 in [3, 4, 3] { hosting.pageShown(browser: browser) }
        #expect(fake.calls.count == 2)
        #expect(hosting.refusals == 2)
        // A move of the host view (a docked DevTools changing place) asks once more.
        hosting.pageMoved(browser: 3)
        #expect(fake.calls.count == 3)
        #expect(try #require(hosting.page).contextID == 11)
        // A new page window starts over.
        fake.contextID = 0
        hosting.pageWindowCreated(browser: 12, fork: fake.fork)
        turn.end()
        #expect(fake.calls.count == 4)
        #expect(hosting.isRetryArmed)
    }

    @Test func requestsAddressTheWindowsLiveBrowserNotTheOneThatCreatedIt() throws {
        let hosting = makeHosting()
        var live: Int32? = 3
        fake.contextID = 0
        // A popup host's window: its about:blank placeholder (3) created it.
        hosting.pageWindowCreated(browser: 3, fork: fake.fork, anchor: { live })
        turn.end()
        #expect(fake.calls.map { $0.browser } == [3])
        // The popup (8) moved in and the placeholder closed before the tracker's read.
        live = 8
        fake.contextID = 9
        hosting.trackerDidRead()
        turn.end()
        #expect(fake.calls.map { $0.browser } == [3, 8])
        #expect(try #require(hosting.page).contextID == 9)

        // No live browser: nothing to address, no call.
        let other = makeHosting()
        other.pageWindowCreated(browser: 5, fork: fake.fork, anchor: { nil })
        turn.end()
        #expect(fake.calls.count == 2)
        #expect(other.forkCalls == 0)
    }

    @Test func teardownAfterThePageWindowClosedMakesNoForkCall() {
        let hosting = makeHosting()
        hosting.pageWindowCreated(browser: 3, fork: fake.fork)
        turn.end()
        #expect(hosting.page != nil)
        // The pane's last tab closed (or DevTools closed): browser 3 is gone.
        hosting.stop()
        #expect(fake.calls.count == 1)
        #expect(hosting.page == nil)
        #expect(view.subviews.isEmpty)
        // Nothing left to address: later events reach no fork.
        hosting.pageShown(browser: 3)
        hosting.trackerDidRead()
        #expect(turn.isEmpty)
        #expect(fake.calls.count == 1)
    }

    /// DevTools has no tab shows: its creation request, the retry at the tracker's read, then each
    /// placement change (dock side, into or out of its own window) is a chance to host, and where a
    /// tunable change applies.
    @Test func aDockedDevToolsAsksAgainAtEachPlacementChange() throws {
        var on = true
        let hosting = makeHosting(enabled: { on })
        let devTools: Int32 = 20
        fake.contextID = 0
        hosting.pageWindowCreated(browser: devTools, fork: fake.fork, anchor: { devTools })
        turn.end()
        hosting.trackerDidRead()
        turn.end()
        #expect(fake.calls.count == 2)
        #expect(hosting.page == nil)
        // Moved to the right side: asked once more, hosted.
        fake.contextID = 13
        hosting.pageMoved(browser: devTools)
        #expect(fake.calls.count == 3)
        #expect(try #require(hosting.page).contextID == 13)
        // Moved again while hosted: no call.
        hosting.pageMoved(browser: devTools)
        #expect(fake.calls.count == 3)
        // Tunable off, then undocked into its own window: hosting off at that move.
        on = false
        hosting.pageMoved(browser: devTools)
        #expect(fake.calls.count == 4)
        #expect(fake.calls.last?.enabled == false)
        #expect(hosting.page == nil)
        // DevTools closed: no call to its gone browser.
        hosting.stop()
        #expect(fake.calls.count == 4)
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

    @Test func aContextNothingCanShowGivesThePageItsWindowBackAndAsksNoMore() {
        let hosting = makeHosting(layerHost: { _ in nil })
        hosting.pageWindowCreated(browser: 3, fork: fake.fork)
        turn.end()
        #expect(fake.calls.map { $0.enabled } == [true, false])
        #expect(hosting.page == nil)
        #expect(view.subviews.isEmpty)
        #expect(hosting.refusals == 1)
        // Not the fork's refusal: a retry would fail the same way.
        #expect(!hosting.isRetryArmed)
        // Every later tab show would turn hosting on and off again (and flash the page): none calls.
        for _ in 0..<3 { hosting.pageShown(browser: 3) }
        hosting.trackerDidRead()
        hosting.pageMoved(browser: 3)
        #expect(turn.isEmpty)
        #expect(fake.calls.count == 2)
        #expect(hosting.refusals == 1)
    }

    @Test func theReportCountsHostedViewsInAWindowOnly() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: .borderless,
                              backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let container = NSView(frame: window.contentRect(forFrameRect: window.frame))
        window.contentView = container
        container.addSubview(view)

        let pane = makeHosting()
        pane.pageWindowCreated(browser: 3, fork: fake.fork)
        let refused = CEFLayerHosting(isEnabled: { true }, schedule: { [turn] in turn.add($0) })
        refused.view = NSView(frame: NSRect(x: 0, y: 0, width: 10, height: 10))
        let refusing = FakeFork()
        refusing.contextID = 0
        refused.pageWindowCreated(browser: 9, fork: refusing.fork)
        turn.end()
        let report = CEFLayerHostingReport(hostings: [pane, refused])
        #expect(report.hostViews == 2)
        #expect(report.hostedPages == 1)
        #expect(report.refusals == 1)
        #expect(report.forkCalls == 2)
        // The page window closed: its view no longer counts.
        pane.stop()
        #expect(CEFLayerHostingReport(hostings: [pane]).hostedPages == 0)

        pane.pageWindowCreated(browser: 4, fork: fake.fork)
        turn.end()
        #expect(pane.isHostedInWindow)
        // A host view out of its window (a pane parked off screen) is not drawing in a window.
        view.removeFromSuperview()
        #expect(!pane.isHostedInWindow)
        #expect(CEFLayerHostingReport(hostings: [pane]).hostedPages == 0)
    }

    /// The SPI the hosted view needs, on the macOS this runs on (14, 15, 26, 27).
    @Test func theSystemsLayerHostTakesAContextID() throws {
        #expect(CEFHostedPageView.canShowContexts)
        #expect(CEFLayerHosting.Fork(shim: nil, apiVersion: 30, canShowContexts: true) == nil)
        let layer = try #require(CEFHostedPageView.layerHost(contextID: 5))
        #expect((layer.value(forKey: "contextId") as? NSNumber)?.uint32Value == 5)
        let page = CEFHostedPageView(frame: NSRect(x: 0, y: 0, width: 10, height: 10))
        #expect(page.host(contextID: 5))
        #expect(page.contextID == 5)
        #expect(page.host(contextID: 0))
        #expect(page.contextID == 0)
    }
}
