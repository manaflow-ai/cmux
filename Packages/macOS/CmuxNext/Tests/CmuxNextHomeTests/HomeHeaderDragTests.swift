import AppKit
@testable import CmuxNextHome
import Testing

/// Lawrence (hq-6d, 2026-10-07): as in Messages, a drag on empty space in
/// Home's header areas (the people list's top strip and the transcript's
/// header with the avatar and name pill) moves the window. The view a click
/// there reaches can move the window; the compose button and the name pill
/// stay buttons that cannot.
@MainActor @Suite(.serialized) struct HomeHeaderDragTests {
    /// The view a mouse-down at `point` (window coordinates) reaches.
    static func hit(_ window: NSWindow, _ point: NSPoint) -> NSView? {
        let content = window.contentView!
        return content.hitTest(content.superview.map { content.convert(point, to: $0) } ?? point)
    }

    static func center(of view: NSView) -> NSPoint {
        view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
    }

    static func buttons(under view: NSView) -> [NSButton] {
        ((view as? NSButton).map { [$0] } ?? []) + view.subviews.filter { !$0.isHidden }.flatMap(buttons(under:))
    }

    @Test func emptyHeaderSpaceMovesTheWindowAndButtonsStayButtons() async throws {
        let (window, sidebar, transcript) = await HomeTransparencyTests.home(light: false)
        defer { window.close() }
        let top = window.contentView!.bounds.height

        // People list: the strip above the search field, left of the compose button.
        let strip = try #require(Self.hit(window, NSPoint(x: 60, y: top - 20)), "a click on the list's top strip")
        #expect(strip.mouseDownCanMoveWindow, "\(type(of: strip)) at the list's top strip cannot move the window")
        let compose = try #require(Self.hit(window, Self.center(of: sidebar.compose)))
        #expect(compose === sidebar.compose, "the compose button still takes its click")
        #expect(!compose.mouseDownCanMoveWindow)

        // Transcript: the header, away from the avatar and the name pill.
        let header = try #require(Self.hit(window, NSPoint(x: transcript.frame.minX + 40, y: top - 30)), "a click on the header")
        #expect(header.mouseDownCanMoveWindow, "\(type(of: header)) at the transcript header cannot move the window")
        let pill = try #require(Self.buttons(under: transcript).first { $0.bezelStyle == .glass && !$0.title.isEmpty },
                                "the header's name pill")
        let pillHit = try #require(Self.hit(window, Self.center(of: pill)))
        #expect(pillHit === pill, "the name pill still takes its click")
        #expect(!pill.mouseDownCanMoveWindow)

        // Below the header the transcript keeps its own clicks (selection, menus).
        let rows = Self.hit(window, NSPoint(x: transcript.frame.midX, y: top / 2))
        #expect(rows?.mouseDownCanMoveWindow == false, "the transcript under the header moves the window")
    }
}
