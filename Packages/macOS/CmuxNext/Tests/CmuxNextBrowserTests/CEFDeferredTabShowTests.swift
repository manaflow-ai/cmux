import AppKit
@testable import CmuxNextBrowser
import CmuxNextDesign
import CmuxNextTestSupport
import Foundation
import CmuxNextWakeups
import CmuxNextWakeupsTestSupport
import Testing

/// NIGHTLY 1.0.0-nightly.4010547037301 (2026-10-24): a link clicked in an agent chat opened the
/// right pane's Chromium page empty, or drawn over only part of the pane until a divider drag.
/// Since PL-cef-tab a tab's browser is made after the frame commits (`CEFPaneHost.createDeferred`):
/// it joins the pane's live window (`tab_add`) or the window still being built (`windowCreated`).
/// Neither path did what `present` does for a tab with a browser: tell layer hosting which page
/// shows and post the geometry change that makes the fork's tracker place and clip the page window
/// over the host view now. A pane's split spring that lands without moving the host view's own
/// frame (its content is held at its rest size) must also leave the page at the landed frame.
///
/// `PageTracker` stands in for the fork's `CmuxParentViewTracker`: it reads the host view's geometry
/// on each `CmuxParentViewGeometryDidChange` post and each frame change of the host view itself, as
/// the tracker does while it follows a superview chain it no longer has (a same-window reparent).
@MainActor @Suite(.serialized, .closesItsWindows) struct CEFDeferredTabShowTests {
    /// A link opens a tab in a pane whose Chromium window is live: it joins as the active tab in the
    /// one `tab_add` (no second activation), layer hosting shows its browser, and the page is placed.
    @Test func aTabJoiningALiveWindowAfterTheFrameIsActivatedOnceAndPlaced() throws {
        let (runtime, root) = try Self.runtime()
        defer { try? FileManager.default.removeItem(at: root) }
        let (host, first, container) = try Self.liveHost(runtime)
        let tracker = PageTracker(host.hostView)

        let link = CEFTab(id: .random(), profile: .default, host: host, runtime: runtime)
        host.add(link)
        host.present(link, in: container)
        #expect(TabSpyShim.added.isEmpty, "the turn that shows the tab joins no window")
        TabSpyShim.activated = []
        tracker.reads = []
        host.createDeferred()

        #expect(TabSpyShim.added.map(\.anchor) == [10], "joined the pane's window after the frame")
        #expect(TabSpyShim.added.map(\.activate) == [1], "Chromium shows the new tab")
        #expect(link.browserID == TabSpyShim.addedBrowser)
        #expect(TabSpyShim.activated.isEmpty, "one activation source: tab_add's")
        #expect(host.lastActivated == TabSpyShim.addedBrowser, "its echo is this host's own")
        #expect(host.hostView.layerHosting.browser == TabSpyShim.addedBrowser, "layer hosting follows the shown page")
        #expect(tracker.reads.last == CEFHostGeometry(of: host.hostView), "the page window is placed over the pane's view")
        _ = first
    }

    /// A tab the pane switched away from before its frame committed joins in the background:
    /// nothing activates it over the tab now shown.
    @Test func aTabNoLongerShownWhenItJoinsIsNotActivated() throws {
        let (runtime, root) = try Self.runtime()
        defer { try? FileManager.default.removeItem(at: root) }
        let (host, first, container) = try Self.liveHost(runtime)

        let link = CEFTab(id: .random(), profile: .default, host: host, runtime: runtime)
        host.add(link)
        host.present(link, in: container)
        host.conceal(link)
        host.present(first, in: container)
        TabSpyShim.activated = []
        host.createDeferred()

        #expect(TabSpyShim.added.map(\.anchor) == [10])
        #expect(TabSpyShim.added.map(\.activate) == [0])
        #expect(TabSpyShim.activated.isEmpty)
        #expect(host.lastActivated == 10)
        #expect(host.hostView.layerHosting.browser == 10)
    }

    @Test func concealingTheShownTabQueuesHostVisibility() throws {
        let (runtime, root) = try Self.runtime()
        defer { try? FileManager.default.removeItem(at: root) }
        let (host, first, _) = try Self.liveHost(runtime)
        #expect(!host.hostView.isHidden)
        host.conceal(first)
        #expect(!host.hostView.isHidden, "conceal queues the host visibility pass")
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        #expect(host.hostView.isHidden, "parking left the Chromium host window visible")
    }

    /// The Codex review's P1: a second tab shown while the pane's first Chromium window is still
    /// being built joins when the window comes up; it is the page shown, placed over the view.
    @Test func aTabQueuedWhileTheWindowIsBuiltIsShownWhenItComesUp() throws {
        let (runtime, root) = try Self.runtime()
        defer { try? FileManager.default.removeItem(at: root) }
        let host = Self.host(runtime)
        var endOfTurn: [@MainActor @Sendable () -> Void] = []
        host.endOfTurn = { endOfTurn.append($0) }
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let first = CEFTab(id: .random(), profile: .default, host: host, runtime: runtime)
        host.add(first)
        host.present(first, in: container)
        host.createDeferred()
        #expect(host.isCreatingWindow)

        let link = CEFTab(id: .random(), profile: .default, host: host, runtime: runtime)
        host.add(link)
        host.present(link, in: container)
        host.createDeferred()
        #expect(link.browserID == nil && link.isCreationPending, "waits for the window")
        let tracker = PageTracker(host.hostView)
        runtime.handle(.afterCreated(browser: 10, request: try #require(runtime.pendingWindows.keys.first), window: 1))
        for block in endOfTurn { block() }

        #expect(link.browserID == TabSpyShim.addedBrowser)
        #expect(TabSpyShim.added.map(\.activate) == [1], "joined as Chromium's active tab")
        #expect(TabSpyShim.activated.isEmpty, "one activation source: tab_add's")
        #expect(host.lastActivated == TabSpyShim.addedBrowser)
        #expect(host.hostView.layerHosting.browser == TabSpyShim.addedBrowser, "layer hosting shows the shown tab, not the window's first")
        #expect(tracker.reads.last == CEFHostGeometry(of: host.hostView), "the shown page is placed over the pane's view")
    }

    /// The Codex review's P1 at 132e71cd: the pane's first tab closes while its Chromium window is
    /// built and a second tab waits for that window. The late browser of the closed tab is closed,
    /// never shown, and the waiting tab asks for a window of its own: it gets its browser, is
    /// Chromium's active tab and is placed over the pane's view (it waited forever, the pane blank).
    @Test func aTabQueuedForAWindowWhoseFirstTabClosedGetsAWindowOfItsOwn() throws {
        let (runtime, root) = try Self.runtime()
        defer { try? FileManager.default.removeItem(at: root) }
        let host = Self.host(runtime)
        var endOfTurn: [@MainActor @Sendable () -> Void] = []
        host.endOfTurn = { endOfTurn.append($0) }
        func endTurn() { while !endOfTurn.isEmpty { endOfTurn.removeFirst()() } }
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let first = CEFTab(id: .random(), profile: .default, host: host, runtime: runtime)
        host.add(first)
        host.present(first, in: container)
        host.createDeferred()
        let firstRequest = try #require(runtime.pendingWindows.keys.first)

        let link = CEFTab(id: .random(), profile: .default, host: host, runtime: runtime)
        host.add(link)
        host.present(link, in: container)
        host.createDeferred()
        #expect(link.browserID == nil && link.isCreationPending, "waits for the window")
        first.close()
        runtime.handle(.afterCreated(browser: 10, request: firstRequest, window: 1))
        #expect(TabSpyShim.closed == [10], "the closed tab's late browser closes")
        endTurn()

        #expect(TabSpyShim.createWindowCalls == 2, "the waiting tab asked for a window of its own")
        let secondRequest = try #require(runtime.pendingWindows.keys.first)
        let tracker = PageTracker(host.hostView)
        runtime.handle(.afterCreated(browser: 12, request: secondRequest, window: 2))
        endTurn()
        runtime.handle(.beforeClose(browser: 10))

        #expect(host.isLive)
        #expect(link.browserID == 12)
        #expect(host.lastActivated == 12, "the new window's own tab is its active one")
        #expect(TabSpyShim.added.isEmpty)
        #expect(host.hostView.layerHosting.browser == 12, "layer hosting shows the waiting tab")
        #expect(tracker.reads.last == CEFHostGeometry(of: host.hostView), "the page is placed over the pane's view")
        #expect(TabSpyShim.closed == [10], "only the late browser closed")
    }

    /// A link opened from an agent chat into a new right pane: the pane grows in on its split spring
    /// while the window is built, its content held at the rest size, so only its ancestors move. When
    /// the window comes up, and again when the spring lands, the page is placed at the pane's frame.
    @Test func aPageOpenedIntoAPaneGrowingInIsPlacedAtThePaneWhenTheWindowComesUpAndWhenItLands() throws {
        let (runtime, root) = try Self.runtime()
        defer { try? FileManager.default.removeItem(at: root) }
        let host = Self.host(runtime)
        var endOfTurn: [@MainActor @Sendable () -> Void] = []
        host.endOfTurn = { endOfTurn.append($0) }
        // The pane (its clip) on the screen's content, and the tab's content held at the pane's rest width.
        let screen = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
        let pane = NSView(frame: NSRect(x: 900, y: 0, width: 0, height: 600))
        screen.addSubview(pane)
        let tab = CEFTab(id: .random(), profile: .default, host: host, runtime: runtime)
        tab.container.frame = NSRect(x: -640, y: 0, width: 640, height: 600)
        pane.addSubview(tab.container)
        host.add(tab)
        host.present(tab, in: tab.container)
        host.createDeferred()
        let tracker = PageTracker(host.hostView)

        // A spring frame: the pane grew to half its width; the held content rides its trailing edge.
        pane.frame = NSRect(x: 580, y: 0, width: 320, height: 600)
        tab.container.setFrameOrigin(NSPoint(x: -320, y: 0))
        runtime.handle(.afterCreated(browser: 10, request: try #require(runtime.pendingWindows.keys.first), window: 1))
        for block in endOfTurn { block() }
        #expect(tracker.reads.last == CEFHostGeometry(of: host.hostView), "placed where the pane is when the window comes up")

        // The spring lands: the pane is at its rest frame; the content's size never changed.
        tracker.reads = []
        pane.frame = NSRect(x: 260, y: 0, width: 640, height: 600)
        tab.container.setFrameOrigin(.zero)
        #expect(tracker.reads.isEmpty, "the host view's own frame did not change")
        tab.container.notifyPaneMotionSettled()
        let landed = try #require(tracker.reads.last)
        #expect(landed == CEFHostGeometry(of: host.hostView))
        #expect(landed.screenRect == NSRect(x: 260, y: 0, width: 640, height: 600), "the page fills the pane, not a mid-motion part of it")
    }

    /// A divider drag resizes the pane: the page follows the host view's new frame.
    @Test func aDividerDragKeepsThePageAtTheHostBounds() throws {
        let (runtime, root) = try Self.runtime()
        defer { try? FileManager.default.removeItem(at: root) }
        let host = Self.host(runtime)
        host.endOfTurn = { $0() }
        let tab = CEFTab(id: .random(), profile: .default, host: host, runtime: runtime)
        tab.container.frame = NSRect(x: 0, y: 0, width: 640, height: 600)
        host.add(tab)
        host.present(tab, in: tab.container)
        host.createDeferred()
        runtime.handle(.afterCreated(browser: 10, request: try #require(runtime.pendingWindows.keys.first), window: 1))
        let tracker = PageTracker(host.hostView)

        tab.container.setFrameSize(NSSize(width: 420, height: 600))
        #expect(host.hostView.frame == tab.container.bounds)
        #expect(tracker.reads.last == CEFHostGeometry(of: host.hostView))
        #expect(tracker.reads.last?.screenRect.size == NSSize(width: 420, height: 600))
    }

    /// cmux#26037: a divider drag joins the shown page's window to the
    /// drag from the drag's first move until its release landed, with no held page size (the page lays out live). The
    /// end reaches the page window that heard the start. cmux-ad m18/m19: a pane never waits for a page, so the drag
    /// deadline is 0 by default and the page window is never asked to hold a frame.
    @Test func aResizeSyncDragJoinsThePageWindowAndNeverWaitsForIt() throws {
        let (runtime, root) = try Self.runtime()
        defer { try? FileManager.default.removeItem(at: root) }
        let (host, first, container) = try Self.liveHost(runtime)
        // In the app the tab's own content view is the pane's container (`CEFTabContentView.viewDidMoveToWindow`).
        let window = NSWindow(contentRect: container.frame, styleMask: .borderless, backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        defer { window.closeAfterTest() }
        window.contentView?.addSubview(first.container)

        TabSpyShim.resizeSyncs = []
        first.container.paneResizeGestureDidChange(active: true)
        #expect(host.hostView.layerHosting.inPaneDrag)
        #expect(first.container.heldPageSize == nil, "the page lays out live")
        #expect(!TabSpyShim.resizeSyncs.contains { $0.timeoutMs > 0 }, "the drag asked a page to hold a frame: \(TabSpyShim.resizeSyncs)")
        first.container.paneResizeGestureDidChange(active: false)
        #expect(!host.hostView.layerHosting.inPaneDrag)
        #expect(first.container.syncedDragHostings.isEmpty)
        #expect(!TabSpyShim.resizeSyncs.contains { $0.timeoutMs > 0 }, "a page waited at the drag's end: \(TabSpyShim.resizeSyncs)")
    }

    /// A zoom of the pane shows in one commit: the shown page takes part in it (``PaneCommitSurface``), so the frame
    /// that shows the zoom has the page laid out at the zoomed size (the tests below). Before, the page took no part
    /// and showed its old frame at the old size beside its white backdrop for two frames, then laid out again
    /// (Lawrence 2026-11-20, the AWS console in a zoom).
    @Test func theShownPageTakesPartInItsPanesCommit() throws {
        let (runtime, root) = try Self.runtime()
        defer { try? FileManager.default.removeItem(at: root) }
        let (_, first, container) = try Self.liveHost(runtime)
        let window = NSWindow(contentRect: container.frame, styleMask: .borderless, backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        defer { window.closeAfterTest() }
        window.contentView?.addSubview(first.container)

        let surfaces = (first.container as NSView).paneCommitSurfaces()
        #expect(surfaces.count == 1 && surfaces.first === first.container, "the shown page takes no part in its pane's commit: \(surfaces)")
    }

    /// A zoom of the page's pane on today's engine (fork API 33: no resize fence). The pane's commit tells the page its
    /// zoomed size ahead: the page takes it now, while the pane still shows the old layout (the pane clips it and its
    /// old frame stays at its top-left corner), and the page is ready for the commit only once it laid out at that size.
    /// So the frame that shows the zoom shows the page laid out at the zoomed size. Before, the page took the size only
    /// in the frame that showed the zoom and was ready at once: the zoom showed the page's old, narrower frame beside
    /// its white backdrop for two to four frames, then the page laid out again (Lawrence 2026-11-20, the AWS console).
    @Test(.timeLimit(.minutes(1)))
    func aGrowingCommitWithoutAFenceSizesThePageAheadAndIsReadyOnceItLaidOut() async throws {
        let (runtime, root) = try Self.runtime()
        defer { try? FileManager.default.removeItem(at: root) }
        let (host, first, window, answers, frames) = try Self.zoomablePage(runtime)
        defer { window.closeAfterTest() }
        let page = first.container
        let scale = window.backingScaleFactor

        let before = CEFHostView.trackerStats
        var ready = 0
        var readyCame: CheckedContinuation<Void, Never>?
        page.commitWillResize(by: CGSize(width: 480, height: 0)) {
            ready += 1
            readyCame?.resume()
            readyCame = nil
        }
        #expect(host.hostView.frame.size == CGSize(width: 880, height: 300), "the page did not take the zoomed size ahead: \(host.hostView.frame)")
        #expect(page.bounds.size == CGSize(width: 400, height: 300), "the page's container took the zoomed size before the commit")
        #expect(page.layer?.masksToBounds == true, "the page drawn ahead is not clipped to its pane's old size")
        #expect(ready == 0, "the page is ready for the zoom before it laid out at the zoomed size")
        frames.tick()
        #expect(ready == 0, "the page is ready for the zoom one frame after the change with no layout")

        // The page's ask runs once this test yields; the answer waits for it.
        if ready == 0 {
            await withCheckedContinuation { done in
                readyCame = done
                answers.answer(true)
            }
        }
        #expect(ready == 1)
        #expect(answers.asked == [CGSize(width: 880 * scale, height: 300 * scale)], "the page was not asked for its layout at the zoomed size")
        // An answer ends the wait at once: no longer bound is asked for, and the wait counts as answered.
        #expect(page.commitWaitTicks == nil, "a page that answered still asks its commit to wait")
        #expect(CEFHostView.trackerStats.commitWaitsAnswered == before.commitWaitsAnswered + 1, "an answered wait is not counted")
        #expect(CEFHostView.trackerStats.commitWaitsAtBound == before.commitWaitsAtBound, "an answered wait is counted at its bound")

        // The frame tick shows the zoom: the container takes the size the page already has.
        page.setFrameSize(CGSize(width: 880, height: 300))
        page.layoutSubtreeIfNeeded()
        #expect(page.heldPageSize == nil, "the page still holds the size it took ahead after the zoom showed")
        #expect(host.hostView.frame == page.bounds)
        #expect(page.layer?.masksToBounds == false)
        for _ in 0..<8 { frames.tick() }
        #expect(ready == 1, "the page reported twice for one commit")
    }

    /// A page that does not lay out at the zoomed size in time asks its commit to wait for it longer than the commit's
    /// own bound (``CEFCommitPageWait/commitTicks``), and is ready at its own bound, one frame under that: it is never
    /// late, so its pane never shows its ground instead of the page. Once it reported it asks for no more.
    @Test func aGrowingCommitWithoutAFenceIsReadyAtItsBoundWhenThePageIsSlow() throws {
        let (runtime, root) = try Self.runtime()
        defer { try? FileManager.default.removeItem(at: root) }
        let (_, first, window, answers, frames) = try Self.zoomablePage(runtime)
        defer { window.closeAfterTest() }
        defer { answers.answer(false) }
        let page = first.container
        #expect(page.commitWaitTicks == nil, "a page with no commit asks one to wait")

        let before = CEFHostView.trackerStats
        var ready = 0
        page.commitWillResize(by: CGSize(width: 480, height: 120)) { ready += 1 }
        #expect(page.commitWaitTicks == CEFCommitPageWait.commitTicks, "a page laying out ahead does not ask its commit to wait for it")
        #expect(CEFCommitPageWait.readyFrames == CEFCommitPageWait.commitTicks - 1, "the page's bound is not one frame under the ticks it asks for")
        for frame in 1..<CEFCommitPageWait.readyFrames {
            frames.tick()
            #expect(ready == 0, "frame \(frame): a slow page is ready before its bound")
        }
        frames.tick()
        #expect(ready == 1, "a slow page is not ready at its bound: its pane would show its ground")
        #expect(page.commitWaitTicks == nil, "a page that reported still asks its commit to wait")
        let after = CEFHostView.trackerStats
        #expect(after.commitWaitsAtBound == before.commitWaitsAtBound + 1, "a wait that reached its bound is not counted at its bound")
        #expect(after.commitWaitsAnswered == before.commitWaitsAnswered, "a wait that reached its bound is counted as answered")
    }

    /// A change taken back before it showed (`commitWillResize(by: .zero)`) gives the page its pane's size again at
    /// once, and a commit that never showed lets the size go after a few frames: the page is never left laid out
    /// larger than its pane.
    @Test func aPageDrawnAheadForACommitThatDoesNotShowTakesItsPanesSizeAgain() throws {
        let (runtime, root) = try Self.runtime()
        defer { try? FileManager.default.removeItem(at: root) }
        let (host, first, window, answers, frames) = try Self.zoomablePage(runtime)
        defer { window.closeAfterTest() }
        defer { answers.answer(false) }
        let page = first.container

        var taken = 0
        page.commitWillResize(by: CGSize(width: 480, height: 0)) {}
        page.commitWillResize(by: .zero) { taken += 1 }
        #expect(taken == 1, "a change taken back is not ready at once")
        #expect(host.hostView.frame.size == CGSize(width: 400, height: 300), "a change taken back left the page at the zoomed size")
        #expect(page.heldPageSize == nil)

        page.commitWillResize(by: CGSize(width: 480, height: 0)) {}
        #expect(host.hostView.frame.size == CGSize(width: 880, height: 300))
        for _ in 0..<8 { frames.tick() }
        #expect(host.hostView.frame.size == CGSize(width: 400, height: 300), "a commit that never showed left the page at the zoomed size")
        #expect(page.heldPageSize == nil)
    }

    /// A pane that gets smaller keeps its own picture through its motion and takes its size at the end, so its page is
    /// not drawn ahead: it is ready at once and keeps its size, as before.
    @Test func aShrinkingCommitDrawsNothingAhead() throws {
        let (runtime, root) = try Self.runtime()
        defer { try? FileManager.default.removeItem(at: root) }
        let (host, first, window, answers, _) = try Self.zoomablePage(runtime)
        defer { window.closeAfterTest() }

        var ready = 0
        first.container.commitWillResize(by: CGSize(width: -200, height: 0)) { ready += 1 }
        #expect(ready == 1)
        #expect(host.hostView.frame.size == CGSize(width: 400, height: 300))
        #expect(answers.asked.isEmpty)
        #expect(first.container.commitWaitTicks == nil, "a shrinking page asks its commit to wait for it")
    }

    /// A swap of the halves of an odd width (683 and 684 points) makes one page one point wider. Its old picture covers
    /// all but that point, so it draws nothing ahead and its commit waits for nothing: the swap shows in the frame of
    /// its change. Drawn ahead, the page showed its wider layout cut to its old pane for two to three frames before the
    /// swap, and the swap came those frames late (cmuxterm-hq#19032 cause 2, half-browser swap, fleet job 9c35cd0a).
    @Test func aOnePointGrowingCommitDrawsNothingAhead() throws {
        let (runtime, root) = try Self.runtime()
        defer { try? FileManager.default.removeItem(at: root) }
        let (host, first, window, answers, _) = try Self.zoomablePage(runtime)
        defer { window.closeAfterTest() }

        for change in [CGSize(width: 1, height: 0), CGSize(width: 0, height: 1), CGSize(width: 1, height: 1)] {
            var ready = 0
            first.container.commitWillResize(by: change) { ready += 1 }
            #expect(ready == 1, "a page one point short of its pane is not ready at once (\(change))")
            #expect(host.hostView.frame.size == CGSize(width: 400, height: 300), "a one-point grow drew the page ahead (\(change))")
            #expect(first.container.heldPageSize == nil, "a one-point grow holds the page at a size (\(change))")
            #expect(first.container.commitWaitTicks == nil, "a one-point grow asks its commit to wait (\(change))")
        }
        #expect(answers.asked.isEmpty, "a one-point grow asked the page for its layout")
    }

    /// Which changes draw a page ahead: a grow of more than a point on a side, with no side smaller.
    @Test func onlyAGrowOfMoreThanAPointDrawsAhead() {
        #expect(CEFTabContentView.drawsAhead(for: CGSize(width: 480, height: 0)))
        #expect(CEFTabContentView.drawsAhead(for: CGSize(width: 1, height: 120)))
        #expect(CEFTabContentView.drawsAhead(for: CGSize(width: 2, height: 0)))
        #expect(!CEFTabContentView.drawsAhead(for: .zero))
        #expect(!CEFTabContentView.drawsAhead(for: CGSize(width: 1, height: 0)))
        #expect(!CEFTabContentView.drawsAhead(for: CGSize(width: 1, height: 1)))
        #expect(!CEFTabContentView.drawsAhead(for: CGSize(width: 0.5, height: 0)))
        #expect(!CEFTabContentView.drawsAhead(for: CGSize(width: -200, height: 0)))
        #expect(!CEFTabContentView.drawsAhead(for: CGSize(width: 480, height: -1)))
    }

    /// Review 1 of cmux#26037: a container that leaves its window mid-drag (its tab closed or moved) may never hear
    /// the drag's end, which the listener holds weakly; it hands its share back as it leaves.
    @Test func aContainerLeavingItsWindowMidDragEndsItsWait() throws {
        let (runtime, root) = try Self.runtime()
        defer { try? FileManager.default.removeItem(at: root) }
        let (host, first, container) = try Self.liveHost(runtime)
        // In the app the tab's own content view is the pane's container (`CEFTabContentView.viewDidMoveToWindow`).
        let window = NSWindow(contentRect: container.frame, styleMask: .borderless, backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        defer { window.closeAfterTest() }
        window.contentView?.addSubview(first.container)

        first.container.paneResizeGestureDidChange(active: true)
        #expect(host.hostView.layerHosting.inPaneDrag)
        first.container.removeFromSuperview()
        #expect(!host.hostView.layerHosting.inPaneDrag)
        #expect(first.container.syncedDragHostings.isEmpty)
    }

    /// A docked DevTools joins the drag when it opens after the first drag move, or when its parked tab becomes
    /// visible, and is never asked to wait (the drag deadline is 0). Hiding it again releases only its share, while
    /// the shared page stays in the drag.
    @Test(arguments: [false, true])
    func dockedDevToolsJoiningAResizeSyncDragWaitsUntilHidden(_ initiallyParked: Bool) throws {
        let (runtime, root) = try Self.runtime()
        defer { try? FileManager.default.removeItem(at: root) }
        let (host, first, container) = try Self.liveHost(runtime)
        let window = NSWindow(contentRect: container.frame, styleMask: .borderless, backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        defer { window.closeAfterTest() }
        window.contentView?.addSubview(first.container)
        first.devToolsController.layout.dock = .bottom

        func openDevTools() {
            first.devToolsController.willOpen()
            first.devToolsController.opened(browser: 20, docked: true)
        }
        if initiallyParked {
            openDevTools()
            first.container.isHidden = true
        }
        first.container.paneResizeGestureDidChange(active: true)
        if initiallyParked {
            first.container.isHidden = false
        } else {
            openDevTools()
        }

        let devTools = try #require(first.devToolsController.views?.host.layerHosting)
        #expect(devTools.inPaneDrag)
        #expect(!TabSpyShim.resizeSyncs.contains { $0.browser == 20 && $0.timeoutMs > 0 }, "DevTools was asked to hold a frame (m18: a pane never waits for a page)")
        first.container.layoutContent()
        first.container.isHidden = true
        #expect(!devTools.inPaneDrag, "hidden DevTools spends no frame wait")
        #expect(host.hostView.layerHosting.inPaneDrag, "the shared page keeps this container's drag share")
        first.container.paneResizeGestureDidChange(active: false)
        #expect(!host.hostView.layerHosting.inPaneDrag)
        #expect(!devTools.inPaneDrag, "repeated layouts did not acquire duplicate shares")
    }

    // MARK: Fixtures

    /// A runtime that outlives the test: a shown tab schedules work (its side panel refresh) that
    /// reads its runtime through an unowned reference after the test returned.
    private static func runtime() throws -> (CEFRuntime, URL) {
        TabSpyShim.reset()
        let root = FileManager.default.temporaryDirectory.appending(path: "cef-deferred-\(UUID().uuidString)", directoryHint: .isDirectory)
        let runtime = CEFRuntime(shim: try TabSpyShim.library(), storage: CEFProfileStorage(root: root))
        _ = Unmanaged.passRetained(runtime)
        TabSpyShim.runtime = runtime
        return (runtime, root)
    }

    private static func host(_ runtime: CEFRuntime) -> CEFPaneHost {
        CEFPaneHost(key: CEFPaneKey(pane: BrowserPaneID(rawValue: UUID().uuidString), profile: .default), runtime: runtime)
    }

    /// A pane's shown page (400 x 300 points) in a window, with the page's layout answers and display frames in the
    /// test's hands (``CEFCommitLayoutWait``).
    private static func zoomablePage(_ runtime: CEFRuntime) throws
        -> (CEFPaneHost, CEFTab, NSWindow, LayoutAnswers, ManualFrames) {
        let (host, first, _) = try liveHost(runtime)
        let answers = LayoutAnswers(), frames = ManualFrames()
        host.commitLayoutWait = CEFCommitLayoutWait(laidOut: answers.laidOut, frames: frames.frames)
        let window = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 400, height: 300), styleMask: .borderless,
                              backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView?.addSubview(first.container)
        first.container.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        first.container.layoutSubtreeIfNeeded()
        #expect(host.hostView.superview === first.container, "the page's host view is not in its container")
        #expect(host.hostView.frame.size == CGSize(width: 400, height: 300))
        return (host, first, window, answers, frames)
    }

    /// A pane showing a Chromium page in its live window (browser 10).
    private static func liveHost(_ runtime: CEFRuntime) throws -> (CEFPaneHost, CEFTab, NSView) {
        let host = host(runtime)
        host.endOfTurn = { $0() }
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let first = CEFTab(id: .random(), profile: .default, host: host, runtime: runtime)
        host.add(first)
        host.present(first, in: container)
        host.createDeferred()
        runtime.handle(.afterCreated(browser: 10, request: try #require(runtime.pendingWindows.keys.first), window: 1))
        #expect(host.isLive)
        #expect(first.browserID == 10)
        #expect(host.hostView.layerHosting.browser == 10)
        return (host, first, container)
    }
}

/// The fork tracker's reads of one host view (see the suite's comment).
@MainActor private final class PageTracker: NSObject {
    var reads: [CEFHostGeometry] = []
    private let view: CEFHostView

    init(_ view: CEFHostView) {
        self.view = view
        super.init()
        view.postsFrameChangedNotifications = true
        for name in [CEFHostView.geometryDidChange, NSView.frameDidChangeNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(read), name: name, object: view)
        }
    }

    @objc private func read() {
        reads.append(CEFHostGeometry(of: view))
    }
}

/// Stand-in shim functions: `cmux_shim_create_window` reports the browser started,
/// `cmux_shim_tab_add` records the window's browser it joins and its activate flag and, as
/// production's shim does, runs the new tab's OnAfterCreated before it returns `addedBrowser`;
/// `cmux_shim_tab_activate` and `cmux_shim_close` record the browser, `cmux_shim_create_window` its calls,
/// `cmux_shim_browser_set_resize_sync` the browser and deadline (and takes it); `cmux_shim_fork_api_version` reports layer hosting
/// (API 27, so a host's `CEFLayerHosting` follows the shown browser); every other function does
/// nothing and returns 0.
private nonisolated enum TabSpyShim {
    static let addedBrowser: Int32 = 11
    nonisolated(unsafe) static var added: [(anchor: Int32, activate: Int32)] = []
    nonisolated(unsafe) static var activated: [Int32] = []
    nonisolated(unsafe) static var closed: [Int32] = []
    nonisolated(unsafe) static var createWindowCalls = 0
    nonisolated(unsafe) static var resizeSyncs: [(browser: Int32, timeoutMs: Int32)] = []
    nonisolated(unsafe) static weak var runtime: CEFRuntime?

    static func reset() {
        added = []
        activated = []
        closed = []
        createWindowCalls = 0
        resizeSyncs = []
        runtime = nil
    }

    static func library() throws -> CEFShimLibrary {
        let createWindow: @convention(c) (Int32, UnsafeMutableRawPointer?, Int32, Int32, UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Int32 = { _, _, _, _, _, _ in
            TabSpyShim.createWindowCalls += 1
            return 1
        }
        let tabAdd: @convention(c) (Int32, UnsafePointer<CChar>?, Int32, Int32) -> Int32 = { anchor, _, _, activate in
            TabSpyShim.added.append((anchor, activate))
            MainActor.assumeIsolated {
                TabSpyShim.runtime?.handle(.afterCreated(browser: TabSpyShim.addedBrowser, request: 0, window: 1))
            }
            return TabSpyShim.addedBrowser
        }
        let tabActivate: @convention(c) (Int32) -> Int32 = { browser in
            TabSpyShim.activated.append(browser)
            return 1
        }
        let close: @convention(c) (Int32) -> Void = { browser in TabSpyShim.closed.append(browser) }
        let resizeSync: @convention(c) (Int32, Int32) -> Int32 = { browser, timeout in
            TabSpyShim.resizeSyncs.append((browser, timeout))
            return 1
        }
        let forkAPIVersion: @convention(c) () -> Int32 = { 27 }
        let nothing: @convention(c) () -> Int = { 0 }
        return try CEFShimLibrary.resolving { name in
            switch name {
            case "cmux_shim_create_window": unsafeBitCast(createWindow, to: UnsafeMutableRawPointer.self)
            case "cmux_shim_tab_add": unsafeBitCast(tabAdd, to: UnsafeMutableRawPointer.self)
            case "cmux_shim_tab_activate": unsafeBitCast(tabActivate, to: UnsafeMutableRawPointer.self)
            case "cmux_shim_close": unsafeBitCast(close, to: UnsafeMutableRawPointer.self)
            case "cmux_shim_browser_set_resize_sync": unsafeBitCast(resizeSync, to: UnsafeMutableRawPointer.self)
            case "cmux_shim_fork_api_version": unsafeBitCast(forkAPIVersion, to: UnsafeMutableRawPointer.self)
            default: unsafeBitCast(nothing, to: UnsafeMutableRawPointer.self)
            }
        }
    }
}

/// The page's layout answers of ``CEFCommitLayoutWait``: each ask is kept, and waits until the test answers. An ask
/// runs in a task that starts only when the test yields, so an answer given before it stays for it, and for every
/// later ask.
@MainActor private final class LayoutAnswers {
    private(set) var asked: [CGSize] = []
    private var waiting: [CheckedContinuation<Bool, Never>] = []
    private var given: Bool?

    var laidOut: CEFCommitLayoutWait.LaidOut {
        { [self] _, pixels in
            asked.append(pixels)
            if let given { return given }
            return await withCheckedContinuation { waiting.append($0) }
        }
    }

    /// Answers every ask still waiting, and every ask from now on.
    func answer(_ laidOut: Bool) {
        given = laidOut
        let all = waiting
        waiting = []
        for ask in all { ask.resume(returning: laidOut) }
    }
}

/// The display frames of ``CEFCommitLayoutWait``, one per ``tick(last:)``.
@MainActor private final class ManualFrames {
    private var clients: [(id: Int, tick: @MainActor (Bool) -> Bool)] = []
    private var next = 0

    var frames: CEFCommitLayoutWait.Frames {
        { [self] _, tick in
            next += 1
            let id = next
            clients.append((id, tick))
            return { [weak self] in self?.clients.removeAll { $0.id == id } }
        }
    }

    /// One display frame for every client still ticking.
    func tick(last: Bool = false) {
        for client in clients where clients.contains(where: { $0.id == client.id }) {
            if !client.tick(last) { clients.removeAll { $0.id == client.id } }
        }
    }
}
