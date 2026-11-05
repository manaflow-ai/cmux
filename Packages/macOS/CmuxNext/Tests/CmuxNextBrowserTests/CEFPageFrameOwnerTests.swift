import AppKit
@testable import CmuxNextBrowser
import CmuxNextDesign
import CmuxNextTestSupport
import Foundation
import QuartzCore
import Testing

/// FRAME OWNER REFACTOR S5 (cmux-ad m14, Lawrence 2026-11-05: "during key resizes AND divider drags, in every frame every
/// browser shows live pixels rendered at that frame's pane size"). With `motion.frameOwner.pages` on, a Chromium page is
/// hosted in the window's own layer tree (fork API 26) and never keeps an old size through a pane resize: in every step of
/// a key resize and of a divider drag its host view takes the pane's page area. The main thread never waits for the page
/// (lead, cmux-ad m14): Chromium's resize wait runs on its UI thread, the app's main thread, so S5 gives every page window
/// a deadline of 0 (fork API 27: no pre-commit wait, no GPU transaction, no post-commit wait). Before S5 a key resize held
/// the page at its start size (the old frame, anchored and clipped) and no page was hosted unless
/// `browserResize.layerHosting` was set.
@MainActor @Suite(.serialized, .closesItsWindows) struct CEFPageFrameOwnerTests {
    /// The main thread's budget for a page's wait in one resize frame: none (cmux-ad m14, lead: the main thread never waits
    /// for a page).
    static let mainThreadWaitBudgetMs: Int32 = 0

    /// A key resize with the switch on: the page follows its pane's page area in every step at the step's size (never the
    /// start size, never scaled), and no page window is asked to hold a commit for its frame.
    @Test func aKeyResizeShowsThePageAtThePanesSizeInEveryStep() throws {
        Self.set(pages: true)
        defer { Self.set(pages: nil) }
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

    /// A divider drag with the switch on and `browserResize.dragResize` at its default: the page is hosted, lays out at every
    /// drag size, and no page window holds a commit for its frame.
    @Test func aDividerDragShowsTheHostedPageAtThePanesSizeInEveryStep() throws {
        Self.set(pages: true)
        defer { Self.set(pages: nil) }
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

    /// The switch on hosts every new page window in the window's layer tree, with `browserResize.layerHosting` at its
    /// default (off): the page's pixels commit with its pane.
    @Test func aNewPageWindowIsHostedInTheWindowsLayers() throws {
        Self.set(pages: true)
        defer { Self.set(pages: nil) }
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
    /// frame. With S5 on it is 0 in a drag, a key resize's page sync and the window's live resize, also with every pre-S5
    /// wait tunable set to 50 ms, so the main thread commits each frame at once; S5 off with those tunables waits (the
    /// half-frame cap). `motion.frameOwner.pagesWait` above 0 (measurement only) stays under half a frame.
    @Test func aPageThatMissesItsFrameNeverHoldsTheMainThread() throws {
        func waitIfThePageMisses(_ fork: FakeFork) -> Int32 { fork.syncs.last?.timeoutMs ?? 0 }
        Self.set(pages: true, syncDeadline: 0.05, dragDeadline: 0.05, liveDeadline: 0.05)
        defer { Self.set(pages: nil) }
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

        // The same tunables with S5 off: a hosted page's frame holds the commit (capped at half a 120 Hz frame).
        Self.set(pages: false, syncDeadline: 0.05, dragDeadline: 0.05, liveDeadline: 0.05)
        hosting.paneResizeDrag(active: true)
        #expect(waitIfThePageMisses(fork) == 4, "SETUP: the fake fork does not see the pre-S5 wait")
        hosting.paneResizeDrag(active: false)

        // S5 on again: 0. The measurement knob: a wait, never past half the shortest display frame (4 ms at 120 Hz).
        Self.set(pages: true)
        hosting.displaysChanged()
        #expect(waitIfThePageMisses(fork) == 0)
        Self.set(pages: true, pagesWait: 0.016)
        hosting.displaysChanged()
        #expect(waitIfThePageMisses(fork) == 4)
        Self.set(pages: true)
        hosting.displaysChanged()
        #expect(waitIfThePageMisses(fork) == 0)
        hosting.stop()
    }

    /// A tab moved to another pane in the same window during a key resize (BrowserPageArea.show adds its page to the
    /// other chrome; AppKit sends no window change, so `viewDidMoveToWindow` does not run): the page lets go of that
    /// resize. Its old pane's page window gives back its wait share (S5 on), and the page holds no size and no hold
    /// (both arms). The new pane gives the page a hold again only if it is in a key resize itself (BrowserChromeView.attach).
    @Test(arguments: [true, false])
    func aTabMovedToAnotherPaneDuringAKeyResizeLetsThatResizeGo(_ pages: Bool) throws {
        Self.set(pages: pages)
        defer { Self.set(pages: nil) }
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
        if pages {
            try #require(host.hostView.layerHosting.inPaneDrag, "SETUP: the key resize gives the page window no share")
        } else {
            try #require(first.container.heldPageSize != nil, "SETUP: the page does not hold through the key resize")
        }

        // The move: the other pane's page area adds the page; it never leaves the window.
        paneB.addSubview(first.container)
        first.container.frame = paneB.bounds
        first.container.layoutSubtreeIfNeeded()

        #expect(!host.hostView.layerHosting.inPaneDrag, "the old pane's page window keeps waiting for a resize the page left")
        #expect(first.container.heldPageSize == nil, "the moved page keeps its old pane's size")
        #expect(first.container.pageMotionHold == nil, "the moved page keeps its old pane's key resize")
        #expect(host.hostView.frame == first.container.bounds, "the moved page is not at its new pane's size")
    }

    /// Lead (cmux-ad m14, STATUS 13602): the S5 films had no hosted page in their ON arm (hosted_pages 0 in all 16 reads),
    /// because the switch applied only at a page's next show and the kit flipped it after the page was up. A Debug switch a
    /// person flips must reach the shown pages at once: flipping `motion.frameOwner.pages` with a page shown asks the fork to
    /// host it, without another show, and the page is hosted; flipping it back gives the page its window again. Driven
    /// through a real runtime and pane host (no new type named here), so the suite compiles on the base and fails there on
    /// behavior. The test waits for the fork's ask itself (a signal), never a count of turns.
    @Test func flippingTheSwitchHostsAShownPageAtOnce() async throws {
        Self.set(pages: false)
        PageSpyShim.hostingContext = 7
        defer {
            Self.set(pages: nil)
            PageSpyShim.hostingContext = 0
        }
        let (runtime, root) = try Self.runtime()
        defer { try? FileManager.default.removeItem(at: root) }
        let (host, first) = try Self.liveHost(runtime)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 600), styleMask: .borderless, backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        defer { window.closeAfterTest() }
        first.container.frame = NSRect(x: 0, y: 0, width: 600, height: 500)
        window.contentView?.addSubview(first.container)
        first.container.layoutSubtreeIfNeeded()
        // With the switch off the new page window made no hosting request (`pageWindowCreated` asks only when wanted).
        try #require(host.hostView.layerHosting.page == nil && PageSpyShim.hostingAsks.isEmpty, "SETUP: hosted with the switch off")

        let on = await Self.nextHostingAsk { Self.set(pages: true) }
        #expect(on == true, "flipping the switch on did not ask the fork to host the shown page")
        #expect(host.hostView.layerHosting.page?.contextID == 7, "the shown page is not hosted after the flip")
        #expect(PageSpyShim.hostingAsks.map(\.enabled) == [true], "the flip did not make one hosting call: \(PageSpyShim.hostingAsks)")

        let off = await Self.nextHostingAsk { Self.set(pages: false) }
        #expect(off == false, "flipping the switch off did not give the page its window back")
        #expect(host.hostView.layerHosting.page == nil)
    }

    /// Lead (cmux-ad m14, STATUS 13849; m18): with DevTools docked, S5 ON missed 40 frames in the held-key film (main p50
    /// 2.92 -> 8.64 ms, 21-28 view layouts per frame against 9-15). Per motion frame only geometry: a page with docked
    /// DevTools follows its pane like a plain page, its tab container lays out once per step (itself: one frame set per view
    /// in it, no layout of anything under it), and the page and DevTools hosts take their part of the pane's size in every
    /// step. No hold: S5 has none.
    @Test func aPageWithDockedDevToolsFollowsItsPaneWithGeometryOnly() throws {
        Self.set(pages: true)
        defer { Self.set(pages: nil) }
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
        Self.set(pages: true)
        defer { Self.set(pages: nil) }
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

    /// The switch off (the default) changes nothing: a key resize still holds the page's size (S3 and the interim rule).
    @Test func theSwitchOffKeepsTodaysKeyResizeHold() throws {
        Self.set(pages: false)
        defer { Self.set(pages: nil) }
        let (runtime, root) = try Self.runtime()
        defer { try? FileManager.default.removeItem(at: root) }
        let (host, first) = try Self.liveHost(runtime)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 600), styleMask: .borderless, backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        defer { window.closeAfterTest() }
        first.container.frame = NSRect(x: 200, y: 0, width: 600, height: 500)
        window.contentView?.addSubview(first.container)
        first.container.layoutSubtreeIfNeeded()
        let held = host.hostView.frame.size
        first.container.holdPage(for: PaneMotionHold(trailing: true, bottom: false))
        #expect(first.container.heldPageSize == held)
        #expect(!host.hostView.layerHosting.inPaneDrag)
        first.container.holdPage(for: nil)
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

    /// The fork's next hosting ask (true: host, false: unhost) after `change`, or nil when none comes. The bound only ends a
    /// failing run; a passing run returns at the ask.
    private static func nextHostingAsk(after change: () -> Void) async -> Bool? {
        let (asks, ask) = AsyncStream.makeStream(of: Bool.self)
        PageSpyShim.onHostingAsk = { ask.yield($0) }
        let bound = Task {
            try? await Task.sleep(for: .seconds(10))
            ask.finish()
        }
        defer {
            bound.cancel()
            PageSpyShim.onHostingAsk = nil
        }
        change()
        for await enabled in asks { return enabled }
        return nil
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

    /// Sets the S5 switch (nil: every tunable here at its default) and the waits it overrides.
    private static func set(pages: Bool?, syncDeadline: Double? = nil, dragDeadline: Double? = nil, liveDeadline: Double? = nil,
                            pagesWait: Double? = nil) {
        let tunables = BrowserResizeTunables.self
        TunableStore.shared.activate(file: nil)
        TunableStore.shared.register(tunables.all)
        TunableStore.shared.set(tunables.dragResize.key, nil)
        // Hosting follows S5 alone here: `browserResize.layerHosting` is on by default since #36311 (hosting is wanted
        // when either is on), so pin it off with S5 set, and reset it with S5.
        TunableStore.shared.set(tunables.layerHosting.key, pages.map { _ in .bool(false) })
        // By key: the S5 tunables are not on the base, where a set is refused and the suite fails on behavior.
        TunableStore.shared.set("motion.frameOwner.pages", pages.map { .bool($0) })
        TunableStore.shared.set(tunables.syncDeadline.key, syncDeadline.map { .number($0) })
        TunableStore.shared.set(tunables.dragResizeDeadline.key, dragDeadline.map { .number($0) })
        TunableStore.shared.set(tunables.liveResizeDeadline.key, liveDeadline.map { .number($0) })
        TunableStore.shared.set("motion.frameOwner.pagesWait", pagesWait.map { .number($0) })
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

/// Stand-in shim: `cmux_shim_create_window` reports the browser started, `cmux_shim_fork_api_version` reports fork API 27
/// (layer hosting and resize sync), `cmux_shim_browser_set_resize_sync` records the browser and deadline and takes it,
/// `cmux_shim_browser_set_layer_hosting` records the ask and answers `hostingContext` (0 by default: refused, the page stays in
/// its window, as the fork does before Chromium put the page in its window); every other function does nothing and returns 0.
private nonisolated enum PageSpyShim {
    nonisolated(unsafe) static var resizeSyncs: [(browser: Int32, timeoutMs: Int32)] = []
    nonisolated(unsafe) static var hostingAsks: [(browser: Int32, enabled: Bool)] = []
    /// The context id a hosting ask gets (0: refused, the default).
    nonisolated(unsafe) static var hostingContext: UInt32 = 0
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
        let forkAPIVersion: @convention(c) () -> Int32 = { 27 }
        let nothing: @convention(c) () -> Int = { 0 }
        return try CEFShimLibrary.resolving { name in
            switch name {
            case "cmux_shim_create_window": unsafeBitCast(createWindow, to: UnsafeMutableRawPointer.self)
            case "cmux_shim_browser_set_resize_sync": unsafeBitCast(resizeSync, to: UnsafeMutableRawPointer.self)
            case "cmux_shim_browser_set_layer_hosting": unsafeBitCast(layerHosting, to: UnsafeMutableRawPointer.self)
            case "cmux_shim_fork_api_version": unsafeBitCast(forkAPIVersion, to: UnsafeMutableRawPointer.self)
            default: unsafeBitCast(nothing, to: UnsafeMutableRawPointer.self)
            }
        }
    }
}
