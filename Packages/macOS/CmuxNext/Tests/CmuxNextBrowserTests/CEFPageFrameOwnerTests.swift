import AppKit
@testable import CmuxNextBrowser
import CmuxNextDesign
import CmuxNextTestSupport
import Foundation
import QuartzCore
import Testing

/// FRAME OWNER REFACTOR S5 (cmux-ad m14, Lawrence 2026-11-05: "during key resizes AND divider drags, in every frame every
/// browser shows live pixels rendered at that frame's pane size"). A Chromium page (the only path since 2026-11-06) is
/// hosted in the window's own layer tree (fork API 26) and never keeps an old size through a pane resize: in every step of
/// a key resize and of a divider drag its host view takes the pane's page area. The main thread never waits for the page
/// (lead, cmux-ad m14): Chromium's resize wait runs on its UI thread, the app's main thread, so S5 gives every page window
/// a deadline of 0 (fork API 27: no pre-commit wait, no GPU transaction, no post-commit wait). Before S5 a key resize held
/// the page at its start size (the old frame, anchored and clipped) and no page was hosted.
@MainActor @Suite(.serialized, .closesItsWindows) struct CEFPageFrameOwnerTests {
    /// The main thread's budget for a page's wait in one resize frame: none (cmux-ad m14, lead: the main thread never waits
    /// for a page).
    static let mainThreadWaitBudgetMs: Int32 = 0

    /// A key resize: the page follows its pane's page area in every step at the step's size (never the
    /// start size, never scaled), and no page window is asked to hold a commit for its frame.
    @Test func aKeyResizeShowsThePageAtThePanesSizeInEveryStep() throws {
        let (runtime, root) = try Self.runtime()
        defer { try? FileManager.default.removeItem(at: root) }
        let (host, first) = try Self.liveHost(runtime)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 600), styleMask: .borderless, backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        defer { window.closeAfterTest() }
        first.container.frame = NSRect(x: 200, y: 0, width: 600, height: 500)
        window.contentView?.addSubview(first.container)
        first.container.layoutSubtreeIfNeeded()
        let page = host.hostView
        try #require(page.superview === first.container && page.frame.width > 0, "SETUP: the page is not shown at a size")
        PageSpyShim.resizeSyncs = []

        first.container.holdPage(for: PaneMotionHold(trailing: true, bottom: false))
        #expect(first.container.heldPageSize == nil, "the page keeps its start size through the key resize (the old frame)")
        var misses: [String] = []
        // A held key press: the pane's leading edge moves right 120 pt and back past its start, as a key resize spring does.
        let steps: [CGFloat] = (0...12).map { CGFloat($0) * 10 } + (0...12).map { CGFloat(12 - 2 * $0) * 10 }
        for (index, dx) in steps.enumerated() {
            first.container.frame = NSRect(x: 200 + dx, y: 0, width: 600 - dx, height: 500)
            first.container.layoutSubtreeIfNeeded()
            if page.frame != first.container.bounds {
                misses.append("step \(index): page \(page.frame), pane page area \(first.container.bounds)")
            }
        }
        #expect(misses.isEmpty, "\(misses.count) of \(steps.count) steps do not show the page at its pane's size: \(misses.prefix(3))")
        // The page window keeps the fork's default, 0: nothing asks it to hold a commit.
        #expect(PageSpyShim.resizeSyncs.isEmpty, "a page window was asked to hold the main thread's commit: \(PageSpyShim.resizeSyncs)")

        first.container.holdPage(for: nil)
        first.container.layoutSubtreeIfNeeded()
        #expect(page.frame == first.container.bounds)
        #expect(!host.hostView.layerHosting.inPaneDrag, "the page sync ends with the key resize")
    }

    /// RESIZE P0 5 (cmux21, macOS 27.0, 120 Hz, 3 films per arm): a key resize keeps the page window attached. Detached
    /// (fork API 30, `cmux_browser_set_detached_hosting`) the key spring's first tick paid 1-4 ms for the detach and the
    /// landing paid it again, and the page in a pane that grew upward showed at its old place for about 25 frames (page
    /// foreign 25/26/26 of the m20 judge); attached it showed at its pane's size in every frame (0/0/0) with the same
    /// missed refreshes (3/4/4 against 3/3/4). A divider drag still detaches (each of its frames moves the page window).
    @Test func aKeyResizeKeepsThePageWindowAttached() throws {
        PageSpyShim.forkAPI = 30
        PageSpyShim.hostingContext = 7
        defer { (PageSpyShim.forkAPI, PageSpyShim.hostingContext) = (27, 0) }
        let (runtime, root) = try Self.runtime()
        defer { try? FileManager.default.removeItem(at: root) }
        let (host, first) = try Self.liveHost(runtime)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 600), styleMask: .borderless, backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        defer { window.closeAfterTest() }
        first.container.frame = NSRect(x: 200, y: 0, width: 600, height: 500)
        window.contentView?.addSubview(first.container)
        first.container.layoutSubtreeIfNeeded()
        // The hosting request of a new page window runs at the end of the run-loop turn: run that one pass.
        CFRunLoopRunInMode(.defaultMode, 0, true)
        let hosting = host.hostView.layerHosting
        try #require(hosting.page != nil, "SETUP: the page is not hosted")
        PageSpyShim.detachAsks = []

        first.container.holdPage(for: PaneMotionHold(trailing: true, bottom: false))
        for dx in stride(from: CGFloat(10), through: 120, by: 10) {
            first.container.frame = NSRect(x: 200 + dx, y: 0, width: 600 - dx, height: 500)
            first.container.layoutSubtreeIfNeeded()
        }
        first.container.holdPage(for: nil)
        first.container.layoutSubtreeIfNeeded()
        #expect(PageSpyShim.detachAsks.isEmpty, "a key resize detached the page window: \(PageSpyShim.detachAsks)")
        #expect(!hosting.isDetached)

        // The control: the same rig sees a divider drag's detach and its landing's attach.
        first.container.paneResizeGestureDidChange(active: true)
        #expect(hosting.isDetached, "SETUP: a divider drag no longer detaches, so this rig sees no detach")
        first.container.paneResizeGestureDidChange(active: false)
        #expect(PageSpyShim.detachAsks.map(\.enabled) == [true, false])
    }

    /// A divider drag: the page is hosted, lays out at every
    /// drag size, and no page window holds a commit for its frame.
    @Test func aDividerDragShowsTheHostedPageAtThePanesSizeInEveryStep() throws {
        let (runtime, root) = try Self.runtime()
        defer { try? FileManager.default.removeItem(at: root) }
        let (host, first) = try Self.liveHost(runtime)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 600), styleMask: .borderless, backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        defer { window.closeAfterTest() }
        first.container.frame = NSRect(x: 0, y: 0, width: 600, height: 500)
        window.contentView?.addSubview(first.container)
        first.container.layoutSubtreeIfNeeded()
        // The hosting request of a new page window runs at the end of the run-loop turn: run that one pass.
        CFRunLoopRunInMode(.defaultMode, 0, true)
        #expect(PageSpyShim.hostingAsks.contains { $0.browser == 10 && $0.enabled }, "the page window was never asked to be hosted")
        let page = host.hostView
        PageSpyShim.resizeSyncs = []

        first.container.paneResizeGestureDidChange(active: true)
        #expect(first.container.heldPageSize == nil, "the page keeps its drag-start size")
        var misses: [String] = []
        for width in stride(from: CGFloat(600), through: 360, by: -20) {
            first.container.setFrameSize(NSSize(width: width, height: 500))
            first.container.layoutSubtreeIfNeeded()
            if page.frame != first.container.bounds { misses.append("width \(width): page \(page.frame)") }
        }
        #expect(misses.isEmpty, "\(misses.count) drag steps do not show the page at its pane's size: \(misses.prefix(3))")
        #expect(PageSpyShim.resizeSyncs.isEmpty, "a page window was asked to hold the main thread's commit: \(PageSpyShim.resizeSyncs)")
        first.container.paneResizeGestureDidChange(active: false)
        #expect(!host.hostView.layerHosting.inPaneDrag)
    }

    /// A split's, close's or zoom's spring resizes the pane in every frame, as a key resize does: its start
    /// (`PaneHostView.announceRest` tells the content its rest, ``PaneMotionTargeting``) begins the key resize's page
    /// sync, so the page follows its pane's page area at each frame's size, and its landing (`notifyPaneMotionSettled`)
    /// ends it, with the page at the final size. The page window stays attached all along, as in a key resize (RESIZE P0
    /// 5): detached (#37754), a page in a pane that grew upward showed at its old place, clipped or blank, and snapped at
    /// the landing (Leo 2026-11-08, ask-1cbd6386ac, softened: "the upwards thing ... shit doesn't look right, shit is not
    /// smooth, shit lags"). The main thread never waits for it.
    @Test func aSplitOrCloseSpringShowsThePageAtThePanesSizeInEveryFrameWithItsWindowAttached() throws {
        PageSpyShim.forkAPI = 30
        PageSpyShim.hostingContext = 7
        defer { (PageSpyShim.forkAPI, PageSpyShim.hostingContext) = (27, 0) }
        let (runtime, root) = try Self.runtime()
        defer { try? FileManager.default.removeItem(at: root) }
        let (host, first) = try Self.liveHost(runtime)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 600), styleMask: .borderless, backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        defer { window.closeAfterTest() }
        first.container.frame = NSRect(x: 0, y: 0, width: 1000, height: 300)
        window.contentView?.addSubview(first.container)
        first.container.layoutSubtreeIfNeeded()
        // The hosting request of a new page window runs at the end of the run-loop turn: run that one pass.
        CFRunLoopRunInMode(.defaultMode, 0, true)
        let page = host.hostView
        let hosting = page.layerHosting
        try #require(hosting.page != nil && page.superview === first.container && page.frame.width > 0 && !hosting.inResizeMotion,
                     "SETUP: the page is not hosted and shown at a size, or is already in a resize motion")
        PageSpyShim.detachAsks = []
        PageSpyShim.resizeSyncs = []

        // The spring's start: the pane above closed, so this pane grows upward, 300 pt taller.
        first.container.notifyPaneMotionWillRest(sizeChange: CGSize(width: 0, height: 300))
        #expect(hosting.inPaneDrag, "the spring's start began no page sync: the page would lay out only at the landing")
        var misses: [String] = []
        var detached: [Int] = []
        for step in 1...12 {
            let dy = CGFloat(step) * 300 / 12
            first.container.frame = NSRect(x: 0, y: 0, width: 1000, height: 300 + dy)
            first.container.layoutSubtreeIfNeeded()
            if page.frame != first.container.bounds { misses.append("step \(step): page \(page.frame), pane page area \(first.container.bounds)") }
            if hosting.inResizeMotion || hosting.isDetached { detached.append(step) }
        }
        #expect(misses.isEmpty, "\(misses.count) of 12 spring frames do not show the page at its pane's size: \(misses.prefix(3))")
        #expect(detached.isEmpty, "the page window left its window in spring frames \(detached): it shows its old place until the landing")
        #expect(PageSpyShim.detachAsks.isEmpty, "a split's or close's spring detached the page window: \(PageSpyShim.detachAsks)")
        #expect(PageSpyShim.resizeSyncs.isEmpty, "a page window was asked to hold the main thread's commit: \(PageSpyShim.resizeSyncs)")

        // The landing: the page sync ends, with the page at the final size.
        first.container.notifyPaneMotionSettled()
        #expect(!hosting.inPaneDrag, "the page sync outlived the spring")
        #expect(PageSpyShim.detachAsks.isEmpty, "the spring's landing asked for a detach or attach: \(PageSpyShim.detachAsks)")
        #expect(page.frame == first.container.bounds)
    }

    /// A spring that starts and retargets (a second close mid-motion tells the content a new rest) is one motion: one page
    /// sync, ended once at the landing; a container that leaves its window mid-spring ends it.
    @Test func aRetargetedSpringIsOneMotionAndAContainerLeavingItsWindowEndsIt() throws {
        let (runtime, root) = try Self.runtime()
        defer { try? FileManager.default.removeItem(at: root) }
        let (host, first) = try Self.liveHost(runtime)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 600), styleMask: .borderless, backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        defer { window.closeAfterTest() }
        first.container.frame = NSRect(x: 200, y: 0, width: 600, height: 500)
        window.contentView?.addSubview(first.container)
        first.container.layoutSubtreeIfNeeded()
        let hosting = host.hostView.layerHosting

        first.container.notifyPaneMotionWillRest(sizeChange: CGSize(width: 200, height: 0))
        first.container.notifyPaneMotionWillRest(sizeChange: CGSize(width: 300, height: 0))
        #expect(hosting.paneDragHolders == 1, "a retarget began a second page sync: \(hosting.paneDragHolders) holders")
        #expect(!hosting.inResizeMotion, "the spring took the page window out of its window")
        first.container.notifyPaneMotionSettled()
        #expect(!hosting.inPaneDrag, "one landing did not end the retargeted spring")

        first.container.notifyPaneMotionWillRest(sizeChange: CGSize(width: -100, height: 0))
        #expect(hosting.inPaneDrag)
        first.container.removeFromSuperview()
        #expect(!hosting.inPaneDrag, "a container that left its window mid-spring kept its page sync")
        #expect(!hosting.inResizeMotion)
    }

    /// Leo's case (2026-11-07): a close hands the keys to the page beside the closing pane, in the close's own turn, before
    /// the spring's first frame. That page's window holds the keys, so it cannot leave the window for the motion
    /// (`CEFLayerHosting.motionChanged`: ordering a key window out moves the keys, #24913), and it used to resize that
    /// attached window in every frame, Chromium's frames at the new sizes coming after the pane had moved: the
    /// shift-then-expand. Now the spring's start lays the page out once, at the size it rests at, and its pixels ride the
    /// pane's top-left corner, clipped by the pane, through the whole spring: one motion, no resize of the key window after
    /// the first frame, no key change, and the first responder and the focus ask stay where they were.
    @Test func aFocusedPageBesideAClosingPaneRidesItsPaneAtItsRestSizeAndKeepsTheKeys() throws {
        // A hosted page on a fork that can detach (API 30): only the keys keep its window in.
        PageSpyShim.forkAPI = 30
        PageSpyShim.hostingContext = 7
        defer { (PageSpyShim.forkAPI, PageSpyShim.hostingContext) = (27, 0) }
        let (runtime, root) = try Self.runtime()
        defer { try? FileManager.default.removeItem(at: root) }
        let (host, first) = try Self.liveHost(runtime)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 600), styleMask: .borderless, backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        defer { window.closeAfterTest() }
        first.container.frame = NSRect(x: 200, y: 0, width: 600, height: 500)
        window.contentView?.addSubview(first.container)
        first.container.layoutSubtreeIfNeeded()
        // The hosting request of a new page window runs at the end of the run-loop turn: run that one pass.
        CFRunLoopRunInMode(.defaultMode, 0, true)
        let page = host.hostView
        let hosting = page.layerHosting
        try #require(hosting.page != nil && !hosting.isDetached, "SETUP: the page is not hosted, or not in the window")
        PageSpyShim.detachAsks = []
        // The close gave this page the keys: its focus ask (the window being key reads the same, `CEFPaneHost`).
        first.keepFocusAsk()
        try #require(window.makeFirstResponder(page), "SETUP: the page's host view did not take the first responder")
        try #require(hosting.holdsFocus() && !hosting.inResizeMotion, "SETUP: the page does not hold the keys, or is in a motion")
        var keyChanges = 0
        first.keyWindows = CEFKeyWindows(keyWindow: { window }, makeKey: { _ in keyChanges += 1 })

        // The spring's start: the left neighbour closed, so the pane rests 200 pt wider, its leading edge 200 pt left.
        first.container.notifyPaneMotionWillRest(sizeChange: CGSize(width: 200, height: 0))
        #expect(first.container.pageRestHold, "the focused page did not wait at its rest")
        #expect(!hosting.isDetached, "the key page window left the window: the keys moved")
        var sizes: [CGSize] = []
        var off: [String] = []
        for step in 1...12 {
            let dx = CGFloat(step) * 200 / 12
            first.container.frame = NSRect(x: 200 - dx, y: 0, width: 600 + dx, height: 500)
            first.container.layoutSubtreeIfNeeded()
            if sizes.last != page.frame.size { sizes.append(page.frame.size) }
            // The top-left corner of the page on the pane's (not flipped: the top is maxY).
            if page.frame.minX != 0 || page.frame.maxY != first.container.bounds.maxY { off.append("step \(step): \(page.frame)") }
        }
        #expect(sizes == [CGSize(width: 800, height: 500)],
                "the key page window took \(sizes.count) sizes in the spring (Chromium lays out at each, after its pane): \(sizes)")
        #expect(off.isEmpty, "the page's pixels left its pane's top-left corner: \(off.prefix(3))")
        #expect(first.container.layer?.masksToBounds == true, "the page at its rest size is not clipped by its smaller pane")

        // A retarget mid-spring (a key press that caught it, a second close) ends the hold: the page follows its pane's
        // page area at each frame's size from here, as every page does.
        first.container.notifyPaneMotionWillRest(sizeChange: CGSize(width: 100, height: 0))
        #expect(!first.container.pageRestHold, "a retarget kept the rest hold")
        first.container.frame = NSRect(x: 50, y: 0, width: 850, height: 500)
        first.container.layoutSubtreeIfNeeded()
        #expect(page.frame == first.container.bounds, "after a retarget the page does not follow its pane: \(page.frame)")
        first.container.frame = NSRect(x: 0, y: 0, width: 900, height: 500)
        first.container.layoutSubtreeIfNeeded()

        first.container.notifyPaneMotionSettled()
        first.container.layoutSubtreeIfNeeded()
        #expect(!first.container.pageRestHold, "the spring's landing did not end the page's rest hold")
        #expect(page.frame == first.container.bounds, "the page is not at its pane's page area after the landing")
        #expect(first.container.heldPageSize == nil, "the page keeps a held size after the landing")
        #expect(window.firstResponder === page, "the motion moved the first responder off the page")
        #expect(first.pendingFocus && hosting.holdsFocus(), "the motion dropped the page's focus ask")
        #expect(keyChanges == 0, "the motion changed the key window \(keyChanges) times")
        #expect(PageSpyShim.detachAsks.isEmpty, "the key page window was asked to leave the window: \(PageSpyShim.detachAsks)")
    }

    /// A key press while a close's spring runs (RESIZE P0 5: a key resize keeps the page attached) takes the pane over: a
    /// focused page's rest hold ends, the page follows the key resize, and both landings leave it on its page area, in the
    /// window, with no held size and no motion running.
    @Test func aKeyResizeThatCatchesASpringLandsThePageOnItsPane() throws {
        PageSpyShim.forkAPI = 30
        PageSpyShim.hostingContext = 7
        defer { (PageSpyShim.forkAPI, PageSpyShim.hostingContext) = (27, 0) }
        let (runtime, root) = try Self.runtime()
        defer { try? FileManager.default.removeItem(at: root) }
        let (host, first) = try Self.liveHost(runtime)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 600), styleMask: .borderless, backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        defer { window.closeAfterTest() }
        first.container.frame = NSRect(x: 200, y: 0, width: 600, height: 500)
        window.contentView?.addSubview(first.container)
        first.container.layoutSubtreeIfNeeded()
        CFRunLoopRunInMode(.defaultMode, 0, true)
        let hosting = host.hostView.layerHosting
        try #require(hosting.page != nil && !hosting.isDetached, "SETUP: the page is not hosted, or not in the window")

        for focused in [false, true] {
            if focused { first.keepFocusAsk() } else { first.dropFocusAsk() }
            first.container.notifyPaneMotionWillRest(sizeChange: CGSize(width: 200, height: 0))
            try #require(first.container.pageRestHold == focused, "SETUP: the spring's rest hold (focused \(focused))")
            first.container.holdPage(for: PaneMotionHold(trailing: true, bottom: false))
            first.container.frame = NSRect(x: 150, y: 0, width: 650, height: 500)
            first.container.layoutSubtreeIfNeeded()
            #expect(first.container.heldPageSize == nil, "the key resize kept the spring's held page (focused \(focused))")
            first.container.notifyPaneMotionSettled()
            first.container.holdPage(for: nil)
            first.container.layoutSubtreeIfNeeded()
            #expect(!hosting.inResizeMotion, "the key resize's landing left a motion running (focused \(focused))")
            #expect(!first.container.pageRestHold, "the key resize's landing left the rest hold (focused \(focused))")
            #expect(!hosting.isDetached, "the page stayed out of the window after both motions landed (focused \(focused))")
            #expect(host.hostView.frame == first.container.bounds)
        }
    }

    /// Every new page window is hosted in the window's layer tree (no switch): the page's pixels commit with its pane.
    @Test func aNewPageWindowIsHostedInTheWindowsLayers() throws {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        defer { withExtendedLifetime(view) {} }
        let (hosting, fork, turn) = Self.hosting(over: view, intervals: [1.0 / 120])
        hosting.pageWindowCreated(browser: 3, fork: fork.fork)
        turn.end()
        #expect(fork.calls.map(\.browser) == [3] && fork.calls.map(\.enabled) == [true], "the page window was not hosted")
        #expect(hosting.page?.contextID == 7)
        hosting.stop()
    }

    /// The page misses every frame (Chromium never draws at the new size in time). Chromium's resize wait runs inside the
    /// app's commit on the main thread for the deadline the fork holds, so that deadline is the main thread's wait per
    /// frame. It is 0 in a drag, a key resize's page sync and the window's live resize, so the main thread commits each
    /// frame at once.
    @Test func aPageThatMissesItsFrameNeverHoldsTheMainThread() throws {
        func waitIfThePageMisses(_ fork: FakeFork) -> Int32 { fork.syncs.last?.timeoutMs ?? 0 }
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        defer { withExtendedLifetime(view) {} }
        let (hosting, fork, turn) = Self.hosting(over: view, intervals: [1.0 / 120])
        hosting.pageWindowCreated(browser: 3, fork: fork.fork)
        turn.end()
        try #require(hosting.page != nil, "SETUP: the page is not hosted")
        var waits: [String: Int32] = ["hosted": waitIfThePageMisses(fork)]
        hosting.paneResizeDrag(active: true)
        waits["drag"] = waitIfThePageMisses(fork)
        hosting.paneResizeDrag(active: false)
        hosting.windowLiveResize(active: true)
        waits["live resize"] = waitIfThePageMisses(fork)
        hosting.windowLiveResize(active: false)
        #expect(waits.values.allSatisfy { $0 <= Self.mainThreadWaitBudgetMs }, "the main thread waits for the page: \(waits)")
        #expect(fork.syncs.isEmpty, "the fork was given a main-thread wait: \(fork.syncs)")

        hosting.stop()
    }

    /// A tab moved to another pane in the same window during a key resize (BrowserPageArea.show adds its page to the
    /// other chrome; AppKit sends no window change, so `viewDidMoveToWindow` does not run): the page lets go of that
    /// resize. Its old pane's page window gives back its wait share, and the page holds no size and no hold. The new pane gives the page a hold again only if it is in a key resize itself (BrowserChromeView.attach).
    @Test func aTabMovedToAnotherPaneDuringAKeyResizeLetsThatResizeGo() throws {
        let (runtime, root) = try Self.runtime()
        defer { try? FileManager.default.removeItem(at: root) }
        let (host, first) = try Self.liveHost(runtime)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 600), styleMask: .borderless, backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        defer { window.closeAfterTest() }
        let paneA = NSView(frame: NSRect(x: 200, y: 0, width: 600, height: 500))
        let paneB = NSView(frame: NSRect(x: 820, y: 0, width: 180, height: 500))
        window.contentView?.addSubview(paneA)
        window.contentView?.addSubview(paneB)
        first.container.frame = paneA.bounds
        paneA.addSubview(first.container)
        first.container.layoutSubtreeIfNeeded()
        first.container.holdPage(for: PaneMotionHold(trailing: true, bottom: false))
        try #require(host.hostView.layerHosting.inPaneDrag, "SETUP: the key resize gives the page window no share")

        // The move: the other pane's page area adds the page; it never leaves the window.
        paneB.addSubview(first.container)
        first.container.frame = paneB.bounds
        first.container.layoutSubtreeIfNeeded()

        #expect(!host.hostView.layerHosting.inPaneDrag, "the old pane's page window keeps waiting for a resize the page left")
        #expect(!host.hostView.layerHosting.inResizeMotion, "the moved page's window stays detached (no clicks) for a motion it left")
        #expect(first.container.heldPageSize == nil, "the moved page keeps its old pane's size")
        #expect(first.container.pageMotionHold == nil, "the moved page keeps its old pane's key resize")
        #expect(host.hostView.frame == first.container.bounds, "the moved page is not at its new pane's size")
    }

    /// Lead (cmux-ad m14, STATUS 13849; m18): with DevTools docked, S5 ON missed 40 frames in the held-key film (main p50
    /// 2.92 -> 8.64 ms, 21-28 view layouts per frame against 9-15). Per motion frame only geometry: a page with docked
    /// DevTools follows its pane like a plain page, its tab container lays out once per step (itself: one frame set per view
    /// in it, no layout of anything under it), and the page and DevTools hosts take their part of the pane's size in every
    /// step. No hold: S5 has none.
    @Test func aPageWithDockedDevToolsFollowsItsPaneWithGeometryOnly() throws {
        LayoutPassGuard.shared.install()
        let (runtime, root) = try Self.runtime()
        defer { try? FileManager.default.removeItem(at: root) }
        let (host, first) = try Self.liveHost(runtime)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 600), styleMask: .borderless, backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        defer { window.closeAfterTest() }
        first.container.frame = NSRect(x: 200, y: 0, width: 600, height: 500)
        window.contentView?.addSubview(first.container)
        first.devToolsController.layout.dock = .bottom
        first.devToolsController.willOpen()
        first.devToolsController.opened(browser: 20, docked: true)
        first.container.layoutSubtreeIfNeeded()
        let devTools = try #require(first.devToolsController.views?.host, "SETUP: no DevTools views")
        try #require(first.devToolsController.reservesRoom && devTools.superview === first.container, "SETUP: DevTools not docked")

        #expect(first.container.holdsPageInPaneMotion, "a page with docked DevTools does not follow its pane")
        first.container.holdPage(for: PaneMotionHold(trailing: true, bottom: false))
        #expect(first.container.heldPageSize == nil, "the page keeps a held size")
        var misses: [String] = []
        let steps: [CGFloat] = (1...12).map { CGFloat($0) * 10 }
        // Only the classes of views in this tab's subtree count (a window an earlier test left open lays out elsewhere).
        let subtree = Self.classNames(under: first.container)
        for dx in steps {
            let before = Self.layoutCalls()
            first.container.frame = NSRect(x: 200 + dx, y: 0, width: 600 - dx, height: 500)
            first.container.layoutSubtreeIfNeeded()
            let calls = Self.layoutCalls().subtracting(before).only(subtree)
            if calls.total > 1 { misses.append("step \(Int(dx)): \(calls.total) layout calls \(calls.byClass)") }
            let frames = first.devToolsController.frames(in: first.container.bounds)
            if host.hostView.frame != frames.page { misses.append("step \(Int(dx)): page \(host.hostView.frame), area \(frames.page)") }
            if devTools.frame != frames.devTools { misses.append("step \(Int(dx)): DevTools \(devTools.frame), area \(frames.devTools)") }
        }
        #expect(misses.isEmpty, "\(misses.count) problems in \(steps.count) steps: \(misses.prefix(4))")
        first.container.holdPage(for: nil)
    }

    /// m18 (Lawrence: "web content is allowed to slightly lag behind it, but must not protrude from it"): a hosted page's
    /// pixels never pass its host view's edge. The hosted view fills the host and clips its context's layers (the fork's
    /// root takes the page window's size, which can be larger than the pane for a frame while it shrinks).
    @Test func aHostedPageNeverDrawsPastItsPane() throws {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        defer { withExtendedLifetime(view) {} }
        let (hosting, fork, turn) = Self.hosting(over: view, intervals: [1.0 / 120])
        hosting.pageWindowCreated(browser: 3, fork: fork.fork)
        turn.end()
        let page = try #require(hosting.page, "SETUP: not hosted")
        // The pane shrinks; the page's last frame is still its old, larger size.
        view.setFrameSize(NSSize(width: 250, height: 300))
        page.layer?.sublayers?.first?.bounds = CGRect(x: 0, y: 0, width: 400, height: 300)
        #expect(page.frame == view.bounds, "the hosted page does not fill its pane's host: \(page.frame) in \(view.bounds)")
        #expect(page.layer?.masksToBounds == true, "the hosted page's layer does not clip to the pane")
        hosting.stop()
    }

    /// m20 item 1 (Lawrence): the gap beside a page smaller than its pane (its last frame while Chromium draws the new
    /// size) shows the PAGE's own color in every motion frame: a key resize, a divider drag, a spring, not only the
    /// window's live resize. The host view under the hosted page paints the page's backdrop whenever one is known.
    @Test func theGapBesideASmallerPageShowsThePagesColorOutsideALiveResize() throws {
        let host = CEFHostView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        defer { window.closeAfterTest() }
        window.contentView?.addSubview(host)
        try #require(!host.inLiveResize, "SETUP: the window is in a live resize")
        let pageColor = CGColor(srgbRed: 0.1, green: 0.4, blue: 0.2, alpha: 1)
        host.pageBackdrop = pageColor
        #expect(host.layer?.backgroundColor == pageColor, "the gap shows the pane ground, not the page's color")
        // A page that is see-through (a cmux page) keeps showing what is under it.
        host.pageSeeThrough = true
        #expect(host.layer?.backgroundColor == nil)
        host.pageSeeThrough = false
        // No page color known yet (before the first real page): the pane ground, as before.
        host.pageBackdrop = nil
        #expect(host.layer?.backgroundColor != nil && host.layer?.backgroundColor != pageColor)
    }

    // MARK: Fixtures

    /// The fork side for ``CEFLayerHosting`` alone: context 7, and every call.
    final class FakeFork {
        private(set) var calls: [(browser: Int32, enabled: Bool)] = []
        private(set) var syncs: [(browser: Int32, timeoutMs: Int32)] = []
        var fork: CEFLayerHosting.Fork {
            CEFLayerHosting.Fork(setLayerHosting: { [self] browser, enabled in
                calls.append((browser, enabled))
                return enabled ? 7 : 0
            }, setResizeSync: { [self] browser, timeout in
                syncs.append((browser, timeout))
                return true
            })
        }
    }

    /// Blocks waiting for the end of the run-loop turn.
    final class Turn {
        private var blocks: [@MainActor @Sendable () -> Void] = []
        func add(_ block: @escaping @MainActor @Sendable () -> Void) { blocks.append(block) }
        func end() {
            let due = blocks
            blocks = []
            for block in due { block() }
        }
    }

    /// A ``CEFLayerHosting`` with its default tunable reads, a fake fork and fixed display rates, over `view` (the hosting
    /// holds its view weakly: the caller keeps it).
    private static func hosting(over view: NSView, intervals: [Double]) -> (CEFLayerHosting, FakeFork, Turn) {
        let fork = FakeFork(), turn = Turn()
        let hosting = CEFLayerHosting(schedule: { turn.add($0) },
                                      makePage: { CEFHostedPageView(frame: $0, makeLayerHost: { _ in CALayer() }) },
                                      refreshIntervals: { intervals })
        hosting.view = view
        return (hosting, fork, turn)
    }

    /// Layout calls so far, by view class (`LayoutPassGuard`).
    private static func layoutCalls() -> LayoutCalls {
        LayoutCalls(byClass: Dictionary(LayoutPassGuard.shared.passesByClass.map { ($0.viewClass, $0.passes) }, uniquingKeysWith: +))
    }

    /// The class names of `view` and every view under it.
    private static func classNames(under view: NSView) -> Set<String> {
        Set([String(describing: type(of: view))]).union(view.subviews.flatMap { classNames(under: $0) })
    }

    struct LayoutCalls {
        var byClass: [String: Int]
        func only(_ classes: Set<String>) -> LayoutCalls { LayoutCalls(byClass: byClass.filter { classes.contains($0.key) }) }
        var total: Int { byClass.values.reduce(0, +) }
        func subtracting(_ earlier: LayoutCalls) -> LayoutCalls {
            LayoutCalls(byClass: byClass.compactMapValues { $0 }.reduce(into: [:]) { out, entry in
                let delta = entry.value - (earlier.byClass[entry.key] ?? 0)
                if delta > 0 { out[entry.key] = delta }
            })
        }
    }

    /// A runtime that outlives the test (a shown tab schedules work that reads it after the test returned).
    private static func runtime() throws -> (CEFRuntime, URL) {
        PageSpyShim.resizeSyncs = []
        PageSpyShim.hostingAsks = []
        let root = FileManager.default.temporaryDirectory.appending(path: "cef-s5-\(UUID().uuidString)", directoryHint: .isDirectory)
        let runtime = CEFRuntime(shim: try PageSpyShim.library(), storage: CEFProfileStorage(root: root))
        _ = Unmanaged.passRetained(runtime)
        return (runtime, root)
    }

    /// A pane showing a Chromium page in its live window (browser 10).
    private static func liveHost(_ runtime: CEFRuntime) throws -> (CEFPaneHost, CEFTab) {
        let host = CEFPaneHost(key: CEFPaneKey(pane: BrowserPaneID(rawValue: UUID().uuidString), profile: .default), runtime: runtime)
        host.endOfTurn = { $0() }
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let first = CEFTab(id: .random(), profile: .default, host: host, runtime: runtime)
        host.add(first)
        host.present(first, in: container)
        host.createDeferred()
        runtime.handle(.afterCreated(browser: 10, request: try #require(runtime.pendingWindows.keys.first), window: 1))
        try #require(host.isLive && first.browserID == 10)
        return (host, first)
    }
}

/// Stand-in shim: `cmux_shim_create_window` reports the browser started, `cmux_shim_fork_api_version` reports `forkAPI`
/// (27 by default: layer hosting and resize sync; 30: `cmux_shim_browser_set_detached_hosting` records each ask in
/// `detachAsks` and takes it), `cmux_shim_browser_set_resize_sync` records the browser and deadline and takes it,
/// `cmux_shim_browser_set_layer_hosting` records the ask and answers `hostingContext` (0 by default: refused, the page stays in
/// its window, as the fork does before Chromium put the page in its window); every other function does nothing and returns 0.
private nonisolated enum PageSpyShim {
    nonisolated(unsafe) static var resizeSyncs: [(browser: Int32, timeoutMs: Int32)] = []
    nonisolated(unsafe) static var hostingAsks: [(browser: Int32, enabled: Bool)] = []
    /// The context id a hosting ask gets (0: refused, the default).
    nonisolated(unsafe) static var hostingContext: UInt32 = 0
    /// The fork API the shim reports (27 by default; 30 adds `cmux_shim_browser_set_detached_hosting`).
    nonisolated(unsafe) static var forkAPI: Int32 = 27
    /// Detach and attach asks (`cmux_shim_browser_set_detached_hosting`), all taken.
    nonisolated(unsafe) static var detachAsks: [(browser: Int32, enabled: Bool)] = []
    /// Told of each hosting ask (enabled), on the main thread.
    nonisolated(unsafe) static var onHostingAsk: (@Sendable (Bool) -> Void)?

    static func library() throws -> CEFShimLibrary {
        let createWindow: @convention(c) (Int32, UnsafeMutableRawPointer?, Int32, Int32, UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Int32 = { _, _, _, _, _, _ in 1 }
        let resizeSync: @convention(c) (Int32, Int32) -> Int32 = { browser, timeout in
            PageSpyShim.resizeSyncs.append((browser, timeout))
            return 1
        }
        let layerHosting: @convention(c) (Int32, Int32) -> UInt32 = { browser, enabled in
            PageSpyShim.hostingAsks.append((browser, enabled != 0))
            PageSpyShim.onHostingAsk?(enabled != 0)
            return enabled != 0 ? PageSpyShim.hostingContext : 0
        }
        let forkAPIVersion: @convention(c) () -> Int32 = { PageSpyShim.forkAPI }
        let detachedHosting: @convention(c) (Int32, Int32) -> Int32 = { browser, enabled in
            PageSpyShim.detachAsks.append((browser, enabled != 0))
            return 1
        }
        let nothing: @convention(c) () -> Int = { 0 }
        return try CEFShimLibrary.resolving { name in
            switch name {
            case "cmux_shim_create_window": unsafeBitCast(createWindow, to: UnsafeMutableRawPointer.self)
            case "cmux_shim_browser_set_resize_sync": unsafeBitCast(resizeSync, to: UnsafeMutableRawPointer.self)
            case "cmux_shim_browser_set_layer_hosting": unsafeBitCast(layerHosting, to: UnsafeMutableRawPointer.self)
            case "cmux_shim_fork_api_version": unsafeBitCast(forkAPIVersion, to: UnsafeMutableRawPointer.self)
            case "cmux_shim_browser_set_detached_hosting": unsafeBitCast(detachedHosting, to: UnsafeMutableRawPointer.self)
            default: unsafeBitCast(nothing, to: UnsafeMutableRawPointer.self)
            }
        }
    }
}
