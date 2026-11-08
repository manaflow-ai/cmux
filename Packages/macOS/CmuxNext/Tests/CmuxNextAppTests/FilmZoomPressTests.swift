#if DEBUG || CMUX_BENCH_HOOKS
import AppKit
@testable import CmuxNextApp
import CmuxNextDesign
@testable import CmuxNextLayout
import CmuxNextTestSupport
import Testing

/// ZOOM VARIANTS 8 (fork only, never merged): ZOOM VARIANTS 7 left the divider catcher panels where they were while a
/// film zoom plays (0.25-0.33 s), so the key's turn does not move them. Two gaps came with it:
/// - a press during the film on a divider's old place went to its old catcher panel, and a press on a new divider over
///   a page went to the page;
/// - the catchers followed only at the film's end signal: with no end (a lost layer animation completion), nothing
///   reported the catchers again.
/// The rule: the catchers follow at the film's end or at its deadline, whichever comes first, and a press during the film
/// goes where the layout is now: the divider at its current place, else the page under the pointer.
/// The test is the clock (120 Hz).
@MainActor @Suite(.serialized, .closesItsWindows) struct FilmZoomPressTests {
    /// A press, drag or release `type` at `point` (screen coordinates), for `window`, as the window server sends one.
    static func event(_ type: NSEvent.EventType, _ point: CGPoint, for window: NSWindow) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(with: type, location: window.convertPoint(fromScreen: point), modifierFlags: [], timestamp: 0,
                                        windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
    }

    static func page() -> ParkedPageCatcherPanelsTests.Layout {
        ParkedPageCatcherPanelsTests.Layout { $0.insetBy(dx: 40, dy: 40) }
    }

    /// The catcher panels that show and take the mouse.
    static func shownPanels(_ layout: ParkedPageCatcherPanelsTests.Layout) -> [DividerMousePanel] {
        (layout.window.childWindows ?? []).compactMap { $0 as? DividerMousePanel }
            .filter { $0.isVisible && !$0.ignoresMouseEvents && $0.frame.size != .zero }
    }

    /// No end signal comes (no layer animation completion): the film's deadline moves the catchers.
    @Test(arguments: ["zoom_variant Z4 K6", "zoom_variant Z4 K12"])
    func theDeadlineMovesTheCatchersWhenNoEndComes(_ variant: String) throws {
        let film = DesignSettings.shared.filmZoom
        defer { DesignSettings.shared.filmZoom = film }
        _ = FilmZoomVariant.select(variant)
        let layout = FilmZoomCatcherTurnTests.Layout()
        defer { layout.window.close() }
        var deadlines: [(Double, @MainActor () -> Void)] = []
        layout.root.context.filmDeadline = { _, delay, work in deadlines.append((delay, work)) }
        let before = layout.catcherAreas
        try #require(!before.isEmpty, "the 2x2 layout's dividers have catcher areas")

        layout.show(.leaf("p1"), zoomed: true)
        _ = layout.root.advanceFrame(1.0 / 120)
        try #require(!layout.root.screenViews["s"]!.frameInput.filmZoomFading.isEmpty, "Z4 zoom in plays its film")
        #expect(layout.catcherAreas == before, "the zoom's key turn moved the catchers")
        let deadline = try #require(deadlines.last, "the film set no deadline: with no end signal the catchers never move")
        #expect(deadline.0 > 0 && deadline.0 < 1, "the deadline \(deadline.0) s is not just past the film")
        deadline.1()
        #expect(!layout.root.catchersWaitForLanding, "the deadline ended the film's wait")
        #expect(layout.catcherAreas == layout.dividerAreas && layout.catcherAreas.isEmpty,
                "at the deadline the catchers follow the zoomed layout (no divider): \(layout.catcherAreas)")
    }

    /// Zoom out over a page: a press on a new divider during the film goes to the divider, not to the page.
    @Test(arguments: ["zoom_variant Z4 K6", "zoom_variant Z4 K12"])
    func aPressOnANewDividerDuringTheFilmDragsTheDivider(_ variant: String) throws {
        let film = DesignSettings.shared.filmZoom
        defer { DesignSettings.shared.filmZoom = film }
        _ = FilmZoomVariant.select(variant)
        let layout = Self.page()
        defer { layout.close() }
        var buttonDown = false
        layout.catchers.isLeftButtonDown = { buttonDown }
        let screen = try #require(layout.root.screenViews["s"])
        layout.show(.leaf("p1"), zoomed: true)
        _ = layout.root.advanceFrame(1.0 / 120)
        screen.filmMotionEnded(screen.frameInput.filmZoomGeneration) // the zoom in's film ends
        layout.land()
        try #require(Self.shownPanels(layout).isEmpty, "zoomed: no divider, no catcher panel")

        layout.show(ParkedPageCatcherPanelsTests.four, zoomed: false)
        _ = layout.root.advanceFrame(1.0 / 120)
        try #require(layout.root.catchersWaitForLanding, "the unzoom's film plays")
        let area = try #require(layout.window.overlayLayer.dividerAreas.first, "the unzoomed layout has dividers")
        let rect = layout.window.convertToScreen(area.rect)
        let point = CGPoint(x: rect.midX, y: rect.midY)
        try #require(layout.page.frame.contains(point), "the page covers the divider")
        try #require(!Self.shownPanels(layout).contains { $0.frame.contains(point) }, "no catcher waits there yet")

        let presses = DividerPressRetarget()
        buttonDown = true
        let took = presses.deliver(try Self.event(.leftMouseDown, point, for: layout.page)) { event, _ in layout.window.overlayLayer.pressTarget(for: event) }
        #expect(took, "the press stayed with the page window over the new divider")
        #expect(layout.root.isDividerDragging, "the press on the divider's current place started no divider drag")
        #expect(Self.shownPanels(layout).contains { $0.frame.contains(point) }, "the catchers did not follow the layout at the press")
        buttonDown = false
        #expect(presses.deliver(try Self.event(.leftMouseUp, point, for: layout.page)) { _, _ in nil }, "the release stayed with the page")
        #expect(!layout.root.isDividerDragging, "the release ended the drag")
    }

    /// Zoom in over a page: a press on a divider's old place during the film goes to the page, not to the old catcher.
    @Test(arguments: ["zoom_variant Z4 K6", "zoom_variant Z4 K12"])
    func aPressOnAnOldDividerPlaceDuringTheFilmGoesToThePage(_ variant: String) throws {
        let film = DesignSettings.shared.filmZoom
        defer { DesignSettings.shared.filmZoom = film }
        _ = FilmZoomVariant.select(variant)
        let layout = Self.page()
        defer { layout.close() }
        layout.catchers.isLeftButtonDown = { true }
        let stale = try #require(Self.shownPanels(layout).first, "the four panes' dividers over the page have catcher panels")
        let point = CGPoint(x: stale.frame.midX, y: stale.frame.midY)

        layout.show(.leaf("p1"), zoomed: true)
        _ = layout.root.advanceFrame(1.0 / 120)
        try #require(layout.root.catchersWaitForLanding, "the zoom in's film plays")
        try #require(Self.shownPanels(layout).contains { $0 === stale }, "the old catcher still waits at the old divider place")

        var target: NSWindow?
        let took = DividerPressRetarget().deliver(try Self.event(.leftMouseDown, point, for: stale)) { event, _ in
            target = layout.window.overlayLayer.pressTarget(for: event)
            return target
        }
        #expect(took && target === layout.page, "the press went to the old catcher, not to the page under it: \(String(describing: target))")
        #expect(!layout.root.isDividerDragging, "a press with no divider under it started a divider drag")
        #expect(Self.shownPanels(layout).isEmpty, "the catchers did not follow the zoomed layout at the press")
    }
}
#endif
