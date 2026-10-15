import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextTabs
import Testing

/// Leo 2026-10-14: tab previews behave like a browser's. A card opens after about 600 ms on a
/// tab; with one open, another tab takes it over at once; leaving the tab hides it at once,
/// also onto the card's own area (nothing on the card takes the pointer); a tab reached within
/// a short grace (about 300 ms, a gap between tabs) shows its card at once. The delays run on
/// a manual clock the test moves.
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
    private static func strip() -> Strip {
        _ = NSApplication.shared
        let tabs = ["a", "b", "c"].map { TabItem(id: TabID($0), title: "Tab \($0)", subtitle: "~/Projects/\($0)") }
        let strip = TabStripView(model: TabStripModel(tabs: tabs, selectedID: TabID("a")))
        let window = NSWindow(contentRect: NSRect(x: 200, y: 400, width: 700, height: 300), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let clock = ManualClock()
        let coordinator = HoverCardCoordinator(clock: clock)
        coordinator.appIsActive = { true }
        coordinator.windowNumberAt = { [weak window] _ in window?.windowNumber }
        // A still real mouse: the coordinator takes each pointer event's own point.
        coordinator.pointerLocation = { .zero }
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 700, height: 300))
        window.contentView = content
        strip.frame = NSRect(x: 0, y: 300 - TabStripView.preferredHeight, width: 700, height: TabStripView.preferredHeight)
        content.addSubview(strip)
        strip.hoverCards = coordinator
        window.orderFrontRegardless()
        strip.layoutSubtreeIfNeeded()
        return Strip(strip: strip, window: window, coordinator: coordinator, clock: clock)
    }

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
        s.clock.advance(by: .milliseconds(700))
        try await settle(until: { s.shows(id) })
        try #require(s.shows(id), "resting on tab \(id) showed no card")
    }

    @Test func aCardOpensAfterAboutSixHundredMilliseconds() async throws {
        let s = Self.strip()
        defer { s.tearDown() }
        s.move(to: try s.center("b"))
        #expect(!s.showsAny, "the card showed on the first frame")
        try await s.clock.waitForSleeper()
        s.clock.advance(by: .milliseconds(450))
        try await Self.settle()
        #expect(!s.showsAny, "the card showed before the delay")
        s.clock.advance(by: .milliseconds(250))
        try await Self.settle(until: { s.shows("b") })
        #expect(s.shows("b"), "no card after 700 ms on the tab")
    }

    @Test func withACardOpenAnotherTabTakesItOverAtOnce() async throws {
        let s = Self.strip()
        defer { s.tearDown() }
        try await Self.open("a", s)
        s.move(to: try s.center("c"))
        #expect(s.shows("c"), "the open card did not swap to the next tab at once")
    }

    @Test func leavingTheTabHidesTheCardAtOnceAlsoOntoTheCard() async throws {
        let s = Self.strip()
        defer { s.tearDown() }
        try await Self.open("a", s)
        let card = try s.cardFrame()
        // Straight down from the tab into the card: nothing on it takes the pointer.
        s.move(to: CGPoint(x: card.midX, y: card.midY))
        #expect(!s.showsAny, "the card stayed with the pointer on it")
        // Back onto a tab within the grace: its card at once.
        s.move(to: try s.center("b"))
        #expect(s.shows("b"), "a tab reached within the grace waited for the delay")
        // Off the strip entirely, past the grace: the next tab waits for the delay again.
        s.move(to: CGPoint(x: s.strip.bounds.midX, y: s.strip.bounds.minY - 120))
        #expect(!s.showsAny, "the card stayed after the pointer left the strip")
        try await s.clock.waitForSleeper()
        s.clock.advance(by: .milliseconds(400))
        try await Self.settle()
        s.move(to: try s.center("c"))
        #expect(!s.showsAny, "past the grace, a new hover showed at once")
    }
}
