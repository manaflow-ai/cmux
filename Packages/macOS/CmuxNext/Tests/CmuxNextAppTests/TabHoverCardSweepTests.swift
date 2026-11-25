import AppKit
@testable import CmuxNextDesign
import CmuxNextResources
@testable import CmuxNextTabs
import CmuxNextTestSupport
import Testing
import CmuxNextWakeupsTestSupport

/// User 2026-11-20 ("feels jank", a 240 fps recording of the pointer sweeping a strip of GitHub tabs, most
/// still loading): frame by frame the card flipped between a tall card with the page's picture and a short
/// one with none (a loading page has no picture yet), and on every tab a "Memory –" row showed for about
/// 80 ms and went (the first sample of a page whose renderer is not matched measures nothing), so the card
/// changed height on nearly every tab. Chrome's card keeps its size across a sweep: a tab with no picture
/// shows a placeholder of the picture's size, and nothing the card learns after it shows a tab (its picture,
/// its first sample) resizes it.
///
/// The sweep: one card open, the pointer crosses tabs with and without a picture and with and without a
/// measurable process. The card's frame is recorded on each move (before anything async lands) and again
/// once the tab's picture fetch and first sample have landed.
@MainActor @Suite(.serialized, .closesItsWindows) struct TabHoverCardSweepTests {
    private struct Strip {
        let strip: TabStripView
        let window: NSWindow
        let coordinator: HoverCardCoordinator
        let clock: ManualClock
        /// Held here: the strip keeps its preview provider and its sample source weakly.
        let previews: any TabPreviewProvider
        let source: MockResourceSource

        func center(_ id: String) throws -> CGPoint {
            let cell = try #require(strip.cells[TabID(id)])
            return strip.convert(CGPoint(x: cell.frame.midX, y: cell.frame.midY), from: strip.tabsClip)
        }

        func move(to point: CGPoint) { strip.updateHover(at: point, moved: true) }
        func shows(_ id: String) -> Bool { coordinator.isShowing(TabHoverCardController.targetID(TabID(id))) }

        /// The card's rest frame on screen (a morph in flight reports where it is going).
        func cardSize() throws -> CGSize {
            let screen = NSRectFromString(try #require(coordinator.report["card_frame"]))
            try #require(screen.width > 0 && screen.height > 0, "no card on screen")
            return screen.size
        }

        var lines: [String] { coordinator.panel?.bodyLines ?? [] }

        func tearDown() {
            coordinator.dismiss(.action)
            coordinator.panel?.closeAfterTest()
            window.contentView = nil
            window.close()
        }
    }

    /// GitHub pages: `a` and `c` loaded (a picture, a renderer the sampler measures), `b` and `d` still
    /// loading (no picture yet, nothing measured).
    private static let loaded: Set<String> = ["a", "c"]

    private static func strip(previews: any TabPreviewProvider) -> Strip {
        _ = NSApplication.shared
        let tabs = ["a", "b", "c", "d"].map { id in
            // A loaded page has its long title (two lines on the card), a loading one only its host.
            let title = loaded.contains(id) ? "Comparing 9650ac9f5ac576bfb210d0cb72991c6e92f555d0...bd9aed0f · manaflow-ai/cmuxterm-hq"
                                            : "github.com"
            var item = TabItem(id: TabID(id), title: title, subtitle: "https://github.com/manaflow-ai/cmuxterm-hq/compare/\(id)")
            item.hover = TabHoverFacts(kind: .browser)
            return item
        }
        let strip = TabStripView(model: TabStripModel(tabs: tabs, selectedID: TabID("a")))
        let window = NSWindow(contentRect: NSRect(x: 200, y: 400, width: 900, height: 400), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let clock = ManualClock()
        let coordinator = HoverCardCoordinator(clock: clock)
        coordinator.appIsActive = { true }
        coordinator.hoverCardsEnabled = { true }
        coordinator.mouseButtonDown = { false }
        coordinator.windowNumberAt = { [weak window] _ in window?.windowNumber }
        coordinator.pointerLocation = { .zero }
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 400))
        window.contentView = content
        strip.frame = NSRect(x: 0, y: 400 - TabStripView.preferredHeight, width: 900, height: TabStripView.preferredHeight)
        content.addSubview(strip)
        strip.hoverCards = coordinator
        strip.hoverCard.previewProvider = previews
        // A loading page's renderer is not matched yet: its sample has the tab with no process.
        let source = MockResourceSource(tabs: tabs.map { item in
            TabResourceSources(tabID: item.id.rawValue, title: item.title, kind: .webkit,
                               processes: loaded.contains(item.id.rawValue) ? [ProcessKey(pid: 400 + Int32(item.id.rawValue.count))] : [])
        })
        strip.hoverCard.resources.setSource(source)
        window.orderFrontRegardless()
        strip.layoutSubtreeIfNeeded()
        return Strip(strip: strip, window: window, coordinator: coordinator, clock: clock, previews: previews, source: source)
    }

    /// A picture for a loaded page, none for a loading one.
    private final class Previews: TabPreviewProvider {
        let image: CGImage? = CGContext(data: nil, width: 16, height: 10, bitsPerComponent: 8, bytesPerRow: 0,
                                        space: CGColorSpaceCreateDeviceRGB(),
                                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage()
        func previewImage(for tab: TabID, maxPixelSize: CGSize) async -> CGImage? {
            TabHoverCardSweepTests.loaded.contains(tab.rawValue) ? image : nil
        }
    }

    /// Lets the tab's picture fetch and first sample land (each a main-actor task).
    private static func settle() async throws {
        for _ in 0..<40 { await Task.yield() }
        for _ in 0..<5 { try await Task.sleep(for: .milliseconds(10)) }
        for _ in 0..<40 { await Task.yield() }
    }

    @Test func sweepingTabsKeepsTheCardsSizeAndRows() async throws {
        Motion.reduceMotionOverride = true
        defer { Motion.reduceMotionOverride = nil }
        let s = Self.strip(previews: Previews())
        defer { s.tearDown() }

        s.move(to: try s.center("a"))
        try await s.clock.waitForSleeper()
        s.clock.advance(by: DesignSettings.shared.hoverCardDelay + .milliseconds(100))
        for _ in 0..<500 where !s.shows("a") { try await Task.sleep(for: .milliseconds(10)) }
        try #require(s.shows("a"), "resting on tab a showed no card")
        try await Self.settle()
        let size = try s.cardSize()

        // Each frame of the sweep: the tab, when it was read, the card's size and its lines.
        var frames: [(tab: String, when: String, size: CGSize, lines: [String])] = [("a", "settled", size, s.lines)]
        for id in ["b", "c", "d", "a", "b"] {
            s.move(to: try s.center(id))
            try #require(s.shows(id), "tab \(id) did not take the card over at once")
            frames.append((id, "on the move", try s.cardSize(), s.lines))
            try await Self.settle()
            try #require(s.shows(id))
            frames.append((id, "settled", try s.cardSize(), s.lines))
        }

        let log = frames.map { "\($0.tab) \($0.when): \(Int($0.size.width))x\(Int($0.size.height)) \($0.lines)" }.joined(separator: "\n")
        for frame in frames {
            #expect(abs(frame.size.width - size.width) < 0.5 && abs(frame.size.height - size.height) < 0.5,
                    "tab \(frame.tab) (\(frame.when)): the card is \(frame.size), not \(size) as on tab a\n\(log)")
            #expect(frame.lines.count == frames[0].lines.count,
                    "tab \(frame.tab) (\(frame.when)): \(frame.lines.count) lines, not \(frames[0].lines.count)\n\(log)")
        }
        // On each tab the card says the same rows on the move and once its sample landed (no row pops in or out).
        for pair in stride(from: 1, to: frames.count, by: 2) {
            let moved = frames[pair].lines.map { $0.components(separatedBy: " ").first ?? "" }
            let settled = frames[pair + 1].lines.map { $0.components(separatedBy: " ").first ?? "" }
            #expect(moved == settled, "tab \(frames[pair].tab): rows \(moved) on the move, \(settled) once settled\n\(log)")
        }
    }

    /// A card opening on a page with no picture yet has the picture's frame from its first frame (a
    /// placeholder), so the picture landing fades in and resizes nothing.
    @Test func aCardWithNoPictureYetHasThePicturesFrame() async throws {
        Motion.reduceMotionOverride = true
        defer { Motion.reduceMotionOverride = nil }
        let s = Self.strip(previews: Previews())
        defer { s.tearDown() }

        s.move(to: try s.center("b"))
        try await s.clock.waitForSleeper()
        s.clock.advance(by: DesignSettings.shared.hoverCardDelay + .milliseconds(100))
        for _ in 0..<500 where !s.shows("b") { try await Task.sleep(for: .milliseconds(10)) }
        try #require(s.shows("b"), "resting on tab b showed no card")
        let first = try s.cardSize()
        try await Self.settle()
        let settled = try s.cardSize()
        #expect(settled == first, "the card changed size after it showed: \(first) then \(settled)")
        s.move(to: try s.center("a"))
        try await Self.settle()
        let withPicture = try s.cardSize()
        #expect(withPicture == first, "a page with a picture has a card of another size: \(withPicture) vs \(first)")
    }
}
