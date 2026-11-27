import AppKit
@testable import CmuxNextDesign
import CmuxNextResources
@testable import CmuxNextTabs
import CmuxNextTestSupport
import Testing
import CmuxNextWakeupsTestSupport

/// Leo 2026-10-14: tab previews behave like a browser's. A card opens after the hover card delay
/// (`sidebar.hoverCards.delay`, `HoverCardTiming.showDelay` by default, cx-23e1f) on a tab; with one open, another
/// tab takes it over at once; leaving the tab hides it at once; a tab reached within the reshow
/// window (a gap between tabs) shows its card at once. The card touches its tab (Lawrence
/// 2026-10-19), but it is a preview the pointer never enters (user 2026-11-16, taking back
/// 2026-10-19's "moving onto it keeps it"): the pointer moving from the tab onto the card hides it.
/// The delays run on a manual clock the test moves.
@MainActor @Suite(.serialized, .closesItsWindows) struct TabHoverCardTimingTests {
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
            coordinator.panel?.closeAfterTest()
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
        let strip = TabStripView(model: TabStripModel(tabs: tabs, selectedID: TabID("a")))
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
        if let source { strip.hoverCard.resources.setSource(source) }
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

    /// Chrome's delay for a standard-width tab (`GetShowDelay`, 1300 ms; Lawrence 2026-11-15): a
    /// pointer that stops on a tab waits all of it, with no early card.
    @Test func aCardOpensAfterChromesWholeDelay() async throws {
        #expect(Self.delay == .milliseconds(1300))
        let s = Self.strip()
        defer { s.tearDown() }
        s.move(to: try s.center("b"))
        #expect(!s.showsAny, "the card showed on the first frame")
        try await s.clock.waitForSleeper()
        s.clock.advance(by: Self.delay - .milliseconds(10))
        try await Self.settle()
        #expect(!s.showsAny, "the card showed before Chrome's delay")
        s.clock.advance(by: .milliseconds(20))
        try await Self.settle(until: { s.shows("b") })
        #expect(s.shows("b"), "no card after Chrome's delay")
    }

    @Test func withACardOpenAnotherTabTakesItOverAtOnce() async throws {
        let s = Self.strip()
        defer { s.tearDown() }
        try await Self.open("a", s)
        s.move(to: try s.center("c"))
        #expect(s.shows("c"), "the open card did not swap to the next tab at once")
    }

    /// User 2026-11-16: "for horizontal tabs i should not be able to hover mouse over horiztonal tab
    /// preview popover thing". The pointer leaving the tab for its card is leaving the tab: the card
    /// fades out on that move, never takes the mouse, and resting on the card past the grace brings
    /// nothing back.
    @Test func thePointerNeverEntersTheCardAndItFadesOutAtOnceOffTheTab() async throws {
        let s = Self.strip()
        defer { s.tearDown() }
        try await Self.open("a", s)
        let panel = try #require(s.coordinator.panel)
        #expect(panel.ignoresMouseEvents, "a tab's card takes the mouse")
        let card = try s.cardFrame()
        let screen = NSRectFromString(try #require(s.coordinator.report["card_frame"]))
        // Straight down from the tab onto the card, as the strip reports it.
        s.move(to: CGPoint(x: card.midX, y: card.midY))
        #expect(!s.showsAny, "the card stayed with the pointer on it: \(s.coordinator.report["phase"] ?? "-")")
        #expect(!panel.isShowingCard, "the fade did not start on the move onto the card")
        // Further over the card, as the coordinator's move monitor reports it: nothing comes back,
        // also resting there past the reshow window.
        s.coordinator.cardPointerMoved(CGPoint(x: screen.midX + 6, y: screen.midY + 6))
        #expect(!s.showsAny, "a move over the fading card brought it back")
        try await s.clock.waitForSleeper()
        s.clock.advance(by: HoverCardTiming.reshowWindow + .milliseconds(100))
        try await Self.settle()
        #expect(!s.showsAny, "resting on where the card was showed it again")
        try await Self.open("b", s)
        let reopened = try #require(s.coordinator.panel)
        // Off the tab and off the strip, away from the card: it fades out on this move, with no grace timer first.
        s.move(to: CGPoint(x: s.strip.bounds.maxX - 10, y: s.strip.bounds.minY - 120))
        #expect(!s.showsAny, "the card stayed after the pointer left its tab: \(s.coordinator.report["phase"] ?? "-")")
        #expect(!reopened.isShowingCard, "the fade did not start on the move off the tab")
        let fade = Motion.hoverCards.duration(.fadeOut)
        let start = ContinuousClock.now
        while reopened.isVisible, reopened.alphaValue > 0.001, ContinuousClock.now - start < .seconds(fade + 1) {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(!reopened.isVisible || reopened.alphaValue <= 0.001, "the card was still at alpha \(reopened.alphaValue)")
        // "At once" is the fade starting on the move (`isShowingCard` above, with the grace
        // timer on the manual clock, which never fires here). This bound only catches a fade
        // that runs far longer than its own: the main actor polls it, and a loaded CI mini
        // late by tens of ms was a false red (0.335 s against fade + 0.25 s, run 41440924263).
        #expect(ContinuousClock.now - start <= .seconds(fade + 0.75), "the fade ran far past its \(fade) s")
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

    /// Answers every tab with one picture and counts the asks.
    private final class Previews: TabPreviewProvider {
        var asked = 0
        let image: CGImage?
        init() {
            let context = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
                                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            image = context?.makeImage()
        }
        func previewImage(for tab: TabID, maxPixelSize: CGSize) async -> CGImage? {
            asked += 1
            return image
        }
    }

    /// A capture of the light theme showed a Markdown tab's card with the page's dark picture: the strip
    /// kept each tab's picture until the tab closed. A theme change now asks the card on screen for its
    /// picture again.
    @Test func aThemeChangeAsksForTheCardsPictureAgain() async throws {
        let s = Self.strip()
        defer { s.tearDown() }
        let previews = Previews()
        s.strip.hoverCard.previewProvider = previews
        try await Self.open("a", s)
        try await Self.settle(until: { previews.asked == 1 })
        try #require(previews.asked == 1, "the card asked for no picture")
        let dark = s.strip.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        s.strip.appearance = NSAppearance(named: dark ? .aqua : .darkAqua)
        try await Self.settle(until: { previews.asked == 2 })
        #expect(previews.asked == 2, "the card kept its picture from the other theme")
    }

    /// Lawrence 2026-11-15 (msg 34360): the card snapped taller when its tab's picture landed; the user
    /// 2026-11-20 (a sweep across loading pages): the card changed size on nearly every tab. The card now
    /// opens with the picture's frame (the tab's glyph in it until the picture is known), and a picture
    /// landing late fades into that frame: the card never changes size for it.
    @Test func aPictureLandingLateFadesIntoTheCardsFrame() async throws {
        Motion.reduceMotionOverride = false
        defer { Motion.reduceMotionOverride = nil }
        let s = Self.strip()
        defer { s.tearDown() }
        let previews = HeldPreviews()
        s.strip.hoverCard.previewProvider = previews
        try await Self.open("a", s)
        try await Self.settle(until: { previews.waiting })
        try #require(previews.waiting, "the card asked for no picture")
        let before = try s.cardFrame()
        // Later than a picture at hand (`instantPicture`): it fades in.
        try await Task.sleep(for: TabHoverCardController.instantPicture + .milliseconds(20))
        previews.release()
        try await Self.settle(until: { s.strip.hoverCard.shownThumbnail != nil })
        try #require(s.strip.hoverCard.shownThumbnail != nil, "the picture never landed")
        try await Self.settle()
        let after = try s.cardFrame().size
        #expect(after == before.size, "the card changed size for its picture: \(before.size) then \(after)")
    }

    /// Leo 2026-11-18, a recording of the pointer resting on a tab: "the hover preview bounces for some
    /// reason". Grown out of its tab (`.morph`), the first card drew a sliver over the tab's lower edge,
    /// then dropped and widened to its size. A tab's card now shows once, at its rest frame, fading in:
    /// no growth and no slide on the first show.
    @Test func aTabsFirstCardShowsAtRestWithNoGrowthOrSlide() async throws {
        #expect(TabTunables.hoverCardEntrance.defaultValue == .fade, "a tab's card grows or slides in by default")
        Motion.reduceMotionOverride = false
        defer { Motion.reduceMotionOverride = nil }
        let s = Self.strip()
        defer { s.tearDown() }
        let before = HoverCardPanel.morphGeneration
        try await Self.open("b", s)
        let panel = try #require(s.coordinator.panel)
        #expect(panel.activeMorph == nil, "the card grew out of its tab")
        #expect(HoverCardPanel.morphGeneration == before, "the first show ran a morph")
        #expect(panel.slideLayer?.animation(forKey: "sublayerTransform") == nil, "the card slid in")
        #expect(panel.contentView?.layer?.animation(forKey: "sublayerTransform") == nil, "the card slid in")
        let drawn = panel.presentedCardFrame, rest = panel.cardFrame
        #expect(abs(drawn.width - rest.width) < 0.5 && abs(drawn.height - rest.height) < 0.5,
                "the first frame draws the card at \(drawn.size), not its rest size \(rest.size)")
    }

    /// Lawrence 2026-11-23 (a recording of a tab's card: "we animate width/height which is bad, should just
    /// fade in"): with a card open, a move to the next tab changes no size on a spring either: the card is
    /// under the next tab at that card's size in the same frame (the first show: `aTabsFirstCardShowsAt...`).
    @Test func aMoveToTheNextTabChangesNoSizeOnASpring() async throws {
        Motion.reduceMotionOverride = false
        defer { Motion.reduceMotionOverride = nil }
        let s = Self.strip()
        defer { s.tearDown() }
        try await Self.open("a", s)
        let before = HoverCardPanel.morphGeneration
        s.move(to: try s.center("b"))
        try await Self.settle(until: { s.shows("b") })
        try #require(s.shows("b"), "the next tab showed no card")
        let panel = try #require(s.coordinator.panel)
        #expect(HoverCardPanel.morphGeneration == before, "the move to the next tab changed the card's size on a spring")
        #expect(panel.activeMorph == nil, "the card is still resizing")
        #expect(panel.slideLayer?.animation(forKey: "sublayerTransform") == nil, "the card slid to the next tab")
    }

    /// A picture that lands when the test says so.
    private final class HeldPreviews: TabPreviewProvider {
        private var held: CheckedContinuation<Void, Never>?
        var waiting: Bool { held != nil }
        let image: CGImage? = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
                                        space: CGColorSpaceCreateDeviceRGB(),
                                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage()
        func previewImage(for tab: TabID, maxPixelSize: CGSize) async -> CGImage? {
            await withCheckedContinuation { held = $0 }
            return image
        }
        func release() {
            held?.resume()
            held = nil
        }
    }
}
