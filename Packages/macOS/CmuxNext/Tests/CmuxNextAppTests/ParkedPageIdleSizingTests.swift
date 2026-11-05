import AppKit
@testable import CmuxNextApp
import CmuxNextCompat
@testable import CmuxNextDesign
import CmuxNextPages
@testable import CmuxNextTabs
import CmuxNextTestSupport
import Testing

/// FRAME OWNER REFACTOR S7b, A2 (pixel-perfect's decision, 2026-11-05): a page parked in a pane keeps its frame while its
/// window or pane resizes (`motion.frameOwner.parkedPages`), and after the motion ends the pane sizes it to the frame it
/// shows at, at the run loop's idle points: one parked page per turn, never while input waits in the queue, at most once
/// per page per motion end. A show that comes first sizes the page itself. So the first show after a resize costs what
/// a show costs today (HomeMessagesReinsertBench: frozen and sized at the show, 7.85 ms p50; today 3.08 ms).
///
/// Every wait here is one pass of the main run loop: the test's own observer at that pass's `beforeWaiting`, at order
/// `.max`, after the sizing's (`.max - 1`), then a wakeup (no timer, no sleep).
@MainActor
@Suite(.serialized, .timeLimit(.minutes(2)), .closesItsWindows)
struct ParkedPageIdleSizingTests {
    static let key = "motion.frameOwner.parkedPages"

    /// A terminal or browser: parked in place, shown under the strip.
    final class Other: NSView, PaneParkableContent {}

    /// Records each size a view takes.
    @MainActor final class Sizes {
        private(set) var all: [CGSize] = []
        private var observer: (any NSObjectProtocol)?

        init(_ view: NSView) {
            view.postsFrameChangedNotifications = true
            // global-notice-allow: a test records one view's frame changes on the default center
            observer = NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: view, queue: nil) {
                [weak self, weak view] _ in
                MainActor.assumeIsolated { if let size = view?.frame.size { self?.all.append(size) } } // main-proof: AppKit posts frame notices on the main thread
            }
        }

        func reset() { all = [] }
        func stop() { observer.map(NotificationCenter.default.removeObserver) }
    }

    struct Rig {
        let window: NSWindow
        let pane: PaneContentView
        let pages: [InternalPageView]
        let other: Other

        /// The size `page` shows at in its pane now.
        func showSize(_ page: InternalPageView) -> CGSize { (pane.parkedFrame(of: page) ?? pane.contentHost.bounds).size }

        func close() { window.close() }
    }

    /// A pane in a window showing `other`, with `count` native internal pages parked in it (shown once each first).
    static func rig(pages count: Int = 1) -> Rig {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 900, height: 600), styleMask: [.titled, .resizable],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let tabs = (0...count).map { TabItem(id: TabID("t\($0)"), title: "Tab \($0)") }
        let pane = PaneContentView(stripModel: TabStripModel(tabs: tabs), reveal: LaunchReveal(deadline: .zero))
        pane.frame = window.contentLayoutRect
        window.contentView = pane
        window.orderFrontRegardless()
        let pages = (0..<count).map { InternalPageView(key: "s7b-idle-\($0)", page: InternalPageID(rawValue: "notes"), content: NSView()) }
        for page in pages {
            pane.show(page)
            settle(pane)
        }
        let other = Other()
        pane.show(other)
        settle(pane)
        return Rig(window: window, pane: pane, pages: pages, other: other)
    }

    static func settle(_ view: NSView) {
        for _ in 0..<3 {
            view.needsLayout = true
            view.layoutSubtreeIfNeeded()
        }
    }

    /// `body` with the switch on where Debug Settings has it.
    static func withSwitch(_ body: () async throws -> Void) async rethrows {
        TunableStore.shared.activate(file: nil)
        TunableStore.shared.register(DesignTunables.all)
        TunableStore.shared.set(key, .bool(true))
        defer { TunableStore.shared.set(key, nil) }
        try await body()
    }

    /// One live resize of the window from its lower-left corner (three steps, smaller), ended as AppKit ends one.
    static func liveResize(_ rig: Rig) {
        Motion.liveResizeOverride = true
        for _ in 1...3 {
            var frame = rig.window.frame
            frame.origin.x += 20
            frame.size.width -= 20
            frame.origin.y += 12
            frame.size.height -= 12
            rig.window.setFrame(frame, display: true)
            rig.window.contentView?.layoutSubtreeIfNeeded()
        }
        Motion.liveResizeOverride = nil
        endLiveResize(rig.pane)
    }

    /// AppKit ends a window's live resize in every view of the window (`viewDidEndLiveResize`), top-down.
    static func endLiveResize(_ view: NSView) {
        view.viewDidEndLiveResize()
        for subview in view.subviews { endLiveResize(subview) }
    }

    /// Waits for the main run loop's next pass to reach its idle point (`beforeWaiting`) and finish every observer there.
    static func nextIdlePoint() async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            MainRunLoopObserver.once(activities: .beforeWaiting, order: .max) { done.resume() }
            CFRunLoopWakeUp(CFRunLoopGetMain())
        }
    }

    /// Runs `body` in one nested pass of the main run loop, in a mode of its own: an `NSApp.postEvent` stops the run loop
    /// running when it is called, and in a test that is the process's outermost one (HomeOpenFocusesComposerTests).
    static func inANestedPass(_ body: @escaping @MainActor () -> Void) {
        let mode = CFRunLoopMode("com.cmuxterm.next.tests.parked-idle" as CFString)
        CFRunLoopPerformBlock(CFRunLoopGetMain(), mode.rawValue) {
            MainActor.assumeIsolated { body() } // main-proof: performed on the main run loop
            CFRunLoopWakeUp(CFRunLoopGetMain())
        }
        _ = CFRunLoopRunInMode(mode, 5, true)
    }

    @Test func afterTheResizeEndsTheParkedPageTakesItsPanesSizeAtTheRunLoopsIdlePoint() async throws {
        try await Self.withSwitch {
            let rig = Self.rig()
            defer { rig.close() }
            let page = rig.pages[0], parked = page.frame
            Self.liveResize(rig)
            #expect(page.frame == parked, "the parked page followed the resize: \(parked) -> \(page.frame)")
            await Self.nextIdlePoint()
            #expect(page.frame.size == rig.showSize(page), "after the resize and an idle point the parked page is \(page.frame.size), not \(rig.showSize(page))")
            #expect(page.isHidden, "the idle sizing showed the page")
        }
    }

    /// A resize outside a live resize (a full screen transition sets its final size at once and ends no live resize; a
    /// one-frame resize): the parked page waits for the run loop's idle point, then takes its pane's size.
    @Test func aResizeOutsideALiveResizeSizesTheParkedPageAtTheIdlePoint() async throws {
        try await Self.withSwitch {
            let rig = Self.rig()
            defer { rig.close() }
            let page = rig.pages[0], parked = page.frame
            var frame = rig.window.frame
            frame.size.width -= 80
            frame.size.height -= 40
            rig.window.setFrame(frame, display: true)
            rig.pane.layoutSubtreeIfNeeded()
            #expect(page.frame == parked, "the parked page followed the resize in its turn: \(parked) -> \(page.frame)")
            await Self.nextIdlePoint()
            #expect(page.frame.size == rig.showSize(page), "after the resize and an idle point the parked page is \(page.frame.size), not \(rig.showSize(page))")
        }
    }

    @Test func aShowBeforeTheIdlePointSizesThePageOnce() async throws {
        try await Self.withSwitch {
            let rig = Self.rig()
            defer { rig.close() }
            let page = rig.pages[0]
            let sizes = Sizes(page)
            defer { sizes.stop() }
            Self.liveResize(rig)
            rig.pane.show(page)
            Self.settle(rig.pane)
            let shown = page.frame.size
            await Self.nextIdlePoint()
            await Self.nextIdlePoint()
            #expect(sizes.all == [shown], "from the resize through the show and two idle points the page took the sizes \(sizes.all), not its show size once")
        }
    }

    @Test func oneParkedPageIsSizedAtEachIdlePoint() async throws {
        try await Self.withSwitch {
            let rig = Self.rig(pages: 2)
            defer { rig.close() }
            Self.liveResize(rig)
            await Self.nextIdlePoint()
            let sized = rig.pages.filter { $0.frame.size == rig.showSize($0) }.count
            #expect(sized == 1, "\(sized) parked pages were sized at the first idle point")
            await Self.nextIdlePoint()
            let after = rig.pages.filter { $0.frame.size == rig.showSize($0) }.count
            #expect(after == 2, "\(after) of 2 parked pages have their pane's size after two idle points")
        }
    }

    /// The known limit (pixel-perfect, 2026-11-05): an internal page that shows a web page (Markdown, a file, Settings)
    /// has no hold for its redraw at a new size, so with the switch on it still follows its pane while parked.
    @Test func aParkedInternalWebPageStillFollowsItsPane() async throws {
        try await Self.withSwitch {
            _ = NSApplication.shared
            let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 900, height: 600), styleMask: [.titled, .resizable],
                                  backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            defer { window.close() }
            let pane = PaneContentView(stripModel: TabStripModel(tabs: [TabItem(id: TabID("files"), title: "Files"),
                                                                         TabItem(id: TabID("term"), title: "Terminal")]),
                                       reveal: LaunchReveal(deadline: .zero))
            pane.frame = window.contentLayoutRect
            window.contentView = pane
            window.orderFrontRegardless()
            let web = try #require(PageWebView(descriptor: .files, routes: []))
            let page = InternalPageView(key: "s7b-web-page", page: InternalPageID(rawValue: "files"), content: web)
            pane.show(page)
            Self.settle(pane)
            pane.show(Other())
            Self.settle(pane)
            try #require(page.isHidden, "SETUP: the page is not parked")
            Motion.liveResizeOverride = true
            var frame = window.frame
            frame.size.width -= 60
            frame.origin.x += 60
            window.setFrame(frame, display: true)
            pane.layoutSubtreeIfNeeded()
            Motion.liveResizeOverride = nil
            let shows = (pane.parkedFrame(of: page) ?? pane.contentHost.bounds).size
            #expect(page.frame.size == shows, "the parked web page did not follow its pane during the resize: \(page.frame.size), not \(shows)")
        }
    }

    /// A parked tab moved to another pane after a resize there: it takes the size it shows at before the destination asks
    /// whether its paint holds, so the hold sees the size change (Codex review of 8acc5dc1363).
    @Test func aParkedPageMovedFromAnotherPaneTakesItsShowSizeBeforeThePaintHoldCheck() async throws {
        try await Self.withSwitch {
            let source = Self.rig(), target = Self.rig(pages: 0)
            defer { source.close(); target.close() }
            let page = source.pages[0]
            var frame = source.window.frame
            frame.size.width -= 120
            source.window.setFrame(frame, display: true)
            source.pane.layoutSubtreeIfNeeded()
            let parkedSize = page.frame.size
            let shows = (target.pane.parkedFrame(of: page) ?? target.pane.contentHost.bounds).size
            try #require(parkedSize != shows, "SETUP: the page would show at its parked size")
            target.pane.contentHost.parkedSizing.willShow(page)
            #expect(page.frame.size == shows, "a page coming from another pane took \(page.frame.size) before its paint hold check, not \(shows)")
            #expect(page.superview === source.pane.contentHost, "the size change moved the page")
        }
    }

    @Test func inputWaitingInTheQueueDefersTheSizing() async throws {
        try await Self.withSwitch {
            let rig = Self.rig()
            defer { rig.close() }
            let page = rig.pages[0], parked = page.frame
            let key = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                    windowNumber: rig.window.windowNumber, context: nil, characters: "a",
                                                    charactersIgnoringModifiers: "a", isARepeat: false, keyCode: 0))
            Self.inANestedPass { NSApp.postEvent(key, atStart: false) }
            Self.liveResize(rig)
            await Self.nextIdlePoint()
            #expect(page.frame == parked, "the parked page was sized while a key waited in the queue: \(page.frame)")
            Self.inANestedPass {
                while NSApp.nextEvent(matching: .any, until: Date.distantPast, inMode: .default, dequeue: true) != nil {}
            }
            await Self.nextIdlePoint()
            #expect(page.frame.size == rig.showSize(page), "with the queue empty the next idle point left the page at \(page.frame.size), not \(rig.showSize(page))")
        }
    }
}
