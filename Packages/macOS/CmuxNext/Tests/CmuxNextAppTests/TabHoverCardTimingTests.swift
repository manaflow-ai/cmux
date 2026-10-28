import AppKit
@testable import CmuxNextDesign
import CmuxNextResources
@testable import CmuxNextTabs
import Testing
import CmuxNextWakeups
import CmuxNextWakeupsTestSupport

/// Leo 2026-10-14: tab previews behave like a browser's. A card opens after the hover card delay
/// (`sidebar.hoverCards.delay`, `HoverCardTiming.showDelay` by default, cx-23e1f) on a tab; with one open, another
/// tab takes it over at once; leaving the tab hides it at once; a tab reached within the reshow
/// window (a gap between tabs) shows its card at once. Lawrence 2026-10-19: the card touches its
/// tab, and the pointer moving from the tab onto the card keeps it. The delays run on a manual
/// clock the test moves.
@MainActor @Suite(.serialized) struct TabHoverCardTimingTests {
    private struct Strip {
        let strip: TabStripView
        let window: NSWindow
        let coordinator: HoverCardCoordinator
        let clock: ManualClock

        func center(_ id: String) throws -> CGPoint {
            let cell = try #require(strip.cells[TabID(id)])
            return strip.convert(CGPoint(x: cell.frame.midX, y: cell.frame.midY), from: strip.tabsClip)
        }

        func move(to point: CGPoint) { strip.updateHover(at: point, moved: true) }
        func shows(_ id: String) -> Bool { coordinator.isShowing(TabHoverCardController.targetID(TabID(id))) }
        var showsAny: Bool { coordinator.machine.shownTarget != nil }

        /// The card on screen, in the strip's coordinates.
        func cardFrame() throws -> CGRect {
            let screen = NSRectFromString(try #require(coordinator.report["card_frame"]))
            try #require(screen.width > 0 && screen.height > 0, "no card on screen")
            return strip.convert(window.convertFromScreen(screen), from: nil)
        }

        func tearDown() {
            coordinator.dismiss(.action)
            window.contentView = nil
            window.close()
        }
    }

    /// Three tabs in an ordered-front window, on a coordinator that hit-tests that window.
    /// `newTabPage` names a tab that is a New Tab page (it has no card).
    private static func strip(newTabPage: String? = nil, source: MockResourceSource? = nil) -> Strip {
        _ = NSApplication.shared
        let tabs = ["a", "b", "c"].map { id in
            var item = TabItem(id: TabID(id), title: "Tab \(id)", subtitle: "~/Projects/\(id)")
            item.isNewTabPage = id == newTabPage
            return item
        }
        let strip = TabStripView.testing(model: TabStripModel(tabs: tabs, selectedID: TabID("a")))
        let window = NSWindow(contentRect: NSRect(x: 200, y: 400, width: 700, height: 300), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let clock = ManualClock()
        let coordinator = HoverCardCoordinator(clock: clock)
        coordinator.appIsActive = { true }
        coordinator.hoverCardsEnabled = { true }
        coordinator.mouseButtonDown = { false }
        coordinator.windowNumberAt = { [weak window] _ in window?.windowNumber }
        // A still real mouse: the coordinator takes each pointer event's own point.
        coordinator.pointerLocation = { .zero }
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 700, height: 300))
        window.contentView = content
        strip.frame = NSRect(x: 0, y: 300 - TabStripView.preferredHeight, width: 700, height: TabStripView.preferredHeight)
        content.addSubview(strip)
        strip.hoverCards = coordinator
        if let source { strip.setResourceSource(source, deadlines: MainDeadlineScheduler(work: MainWorkScheduler(budget: MainFrameBudget()))) }
        window.orderFrontRegardless()
        strip.layoutSubtreeIfNeeded()
        return Strip(strip: strip, window: window, coordinator: coordinator, clock: clock)
    }

    /// The pointer rest before a tab's card opens, as Settings has it.
    private static var delay: Duration { DesignSettings.shared.hoverCardDelay }

    /// Lets a deadline the clock reached reach the coordinator (the timer wakes off the main
    /// actor and hops back). With `done`, waits for it (bounded).
    private static func settle(until done: (() -> Bool)? = nil) async throws {
        for _ in 0..<20 { await Task.yield() }
        for _ in 0..<(done == nil ? 3 : 500) where done?() != true { try await Task.sleep(for: .milliseconds(10)) }
    }

    /// Rests on `id` until its card shows.
    private static func open(_ id: String, _ s: Strip) async throws {
        s.move(to: try s.center(id))
        try await s.clock.waitForSleeper()
        s.clock.advance(by: delay + .milliseconds(100))
        try await settle(until: { s.shows(id) })
        try #require(s.shows(id), "resting on tab \(id) showed no card")
    }

    @Test func aCardOpensAfterTheHoverCardDelay() async throws {
        let s = Self.strip()
        defer { s.tearDown() }
        s.move(to: try s.center("b"))
        #expect(!s.showsAny, "the card showed on the first frame")
        try await s.clock.waitForSleeper()
        s.clock.advance(by: Self.delay - .milliseconds(150))
        try await Self.settle()
        #expect(!s.showsAny, "the card showed before the delay")
        s.clock.advance(by: .milliseconds(250))
        try await Self.settle(until: { s.shows("b") })
        #expect(s.shows("b"), "no card after the delay on the tab")
    }

    @Test func withACardOpenAnotherTabTakesItOverAtOnce() async throws {
        let s = Self.strip()
        defer { s.tearDown() }
        try await Self.open("a", s)
        s.move(to: try s.center("c"))
        #expect(s.shows("c"), "the open card did not swap to the next tab at once")
    }

    @Test func theCardStaysWithThePointerOnItAndFadesOutAtOnceOffIt() async throws {
        let s = Self.strip()
        defer { s.tearDown() }
        try await Self.open("a", s)
        let card = try s.cardFrame()
        // Straight down from the tab onto the card: it stays, also resting there past the grace.
        s.move(to: CGPoint(x: card.midX, y: card.midY))
        #expect(s.shows("a"), "the card hid as the pointer moved from its tab onto it")
        try await s.clock.waitForSleeper()
        s.clock.advance(by: HoverCardTiming.reshowWindow + .milliseconds(100))
        try await Self.settle()
        #expect(s.shows("a"), "the card hid with the pointer resting on it")
        // Off the card and off the strip: it fades out on this move, with no grace timer first.
        s.move(to: CGPoint(x: s.strip.bounds.midX, y: s.strip.bounds.minY - 120))
        #expect(!s.showsAny, "the card stayed after the pointer left it: \(s.coordinator.report["phase"] ?? "-")")
        let panel = try #require(s.coordinator.panel)
        #expect(!panel.isShowingCard, "the fade did not start on the move off the card")
        let fade = Motion.hoverCards.duration(.fadeOut)
        let start = ContinuousClock.now
        while panel.isVisible, panel.alphaValue > 0.001, ContinuousClock.now - start < .seconds(fade + 1) {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(!panel.isVisible || panel.alphaValue <= 0.001, "the card was still at alpha \(panel.alphaValue)")
        #expect(ContinuousClock.now - start <= .seconds(fade + 0.25), "the fade ran past its \(fade) s")
        // Back onto a tab within the grace: its card at once.
        s.move(to: try s.center("b"))
        #expect(s.shows("b"), "a tab reached within the grace waited for the delay")
        // Off the strip entirely, past the grace: the next tab waits for the delay again.
        s.move(to: CGPoint(x: s.strip.bounds.midX, y: s.strip.bounds.minY - 120))
        #expect(!s.showsAny, "the card stayed after the pointer left the strip")
        try await s.clock.waitForSleeper()
        s.clock.advance(by: HoverCardTiming.reshowWindow + .milliseconds(100))
        try await Self.settle()
        s.move(to: try s.center("c"))
        #expect(!s.showsAny, "past the grace, a new hover showed at once")
        s.move(to: CGPoint(x: s.strip.bounds.midX, y: s.strip.bounds.minY - 120))
        try await Self.settle(until: { s.coordinator.machine.phase == .idle })
        #expect(s.coordinator.machine.phase == .idle, "leaving before the delay left a card pending")
    }

    /// Lawrence 2026-10-19: the card sits right against its tab, no gap for the pointer to cross.
    @Test func theCardTouchesItsTab() async throws {
        Motion.reduceMotionOverride = true
        defer { Motion.reduceMotionOverride = nil }
        let s = Self.strip()
        defer { s.tearDown() }
        try await Self.open("b", s)
        let cell = try #require(s.strip.cells[TabID("b")])
        let tab = s.window.convertToScreen(s.strip.tabsClip.convert(cell.frame, to: nil))
        let card = NSRectFromString(try #require(s.coordinator.report["card_frame"]))
        let scale = s.window.backingScaleFactor
        // The strip is at the window's top, so the card opens below the tab.
        let gap = tab.minY - card.maxY
        #expect(gap <= 0.001, "a \(gap) pt gap between the tab and its card")
        #expect(gap > -1 / scale - 0.001, "the card overlaps its tab by \(-gap) pt")
        #expect(abs(card.minX - tab.minX) < 0.5, "the card is not aligned with its tab")
    }

    /// Chrome: a click or Esc on a tab ends its card until the pointer leaves that tab; a
    /// small move on the same tab does not bring it back.
    @Test func aClickKeepsTheCardAwayUntilThePointerLeavesTheTab() async throws {
        let s = Self.strip()
        defer { s.tearDown() }
        try await Self.open("a", s)
        s.coordinator.dismiss(.click)
        #expect(!s.showsAny, "the click did not end the card")
        let a = try s.center("a")
        s.move(to: CGPoint(x: a.x + 1, y: a.y))
        s.clock.advance(by: Self.delay + .milliseconds(300))
        try await Self.settle()
        #expect(!s.showsAny, "a 1-px move on the clicked tab brought its card back")
        // Away from the tab and back: its card waits the delay again.
        s.move(to: CGPoint(x: s.strip.bounds.midX, y: s.strip.bounds.minY - 120))
        try await Self.open("a", s)
    }

    /// The pointer crossing a tab with no card (a New Tab page) or a gap keeps swapping:
    /// the card stays for the grace and the next tab takes it over, with no hide and reshow.
    @Test func crossingANewTabPageTabSwapsWithoutHiding() async throws {
        let s = Self.strip(newTabPage: "b")
        defer { s.tearDown() }
        try await Self.open("a", s)
        s.move(to: try s.center("b"))
        #expect(s.shows("a"), "the card hid while the pointer crossed a New Tab page tab")
        s.move(to: try s.center("c"))
        #expect(s.shows("c"), "the tab past it did not take the card over at once")
        // Resting on the New Tab page tab past the grace: the card goes.
        s.move(to: try s.center("b"))
        try await s.clock.waitForSleeper()
        s.clock.advance(by: HoverCardTiming.reshowWindow + .milliseconds(100))
        try await Self.settle(until: { !s.showsAny })
        #expect(!s.showsAny, "the card stayed on a tab that has none")
    }

    /// Sweeping across tabs before any card shows samples nothing; the shown card samples.
    @Test func onlyAShownCardSamplesItsTab() async throws {
        let mock = MockResourceSource(tabs: ["a", "b", "c"].map {
            TabResourceSources(tabID: $0, title: $0, kind: .terminal, processes: [ProcessKey(pid: 1)])
        })
        let s = Self.strip(source: mock)
        defer { s.tearDown() }
        for id in ["a", "b", "c"] { s.move(to: try s.center(id)) }
        #expect(!s.strip.hoverCard.resources.isOpen, "a pending card sampled its tab")
        try await s.clock.waitForSleeper()
        s.clock.advance(by: Self.delay + .milliseconds(100))
        try await Self.settle(until: { s.shows("c") })
        #expect(s.strip.hoverCard.resources.target == .tab("c"), "the shown card did not sample its tab")
    }
}
