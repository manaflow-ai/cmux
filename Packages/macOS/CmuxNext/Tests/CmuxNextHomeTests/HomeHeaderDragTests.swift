import AppKit
@testable import CmuxNextHome
import Testing

/// Lawrence (hq-6d, 2026-10-07): as in Messages, a drag on empty space in
/// Home's header areas (the people list's top strip and the transcript's
/// header with the avatar and name pill) moves the window. A mouse-down
/// there starts the window's own drag (`NSWindow.performDrag(with:)`); the
/// compose button and the name pill stay buttons, and the transcript under
/// the header keeps its clicks.
@MainActor @Suite(.serialized) struct HomeHeaderDragTests {
    /// Records the window drags its views start.
    final class DragRecordingWindow: NSWindow {
        var drags = 0
        override func performDrag(with event: NSEvent) { drags += 1 }
    }

    /// The view a mouse-down at `point` (window coordinates) reaches.
    static func hit(_ window: NSWindow, _ point: NSPoint) -> NSView? {
        let content = window.contentView!
        return content.hitTest(content.superview.map { content.convert(point, to: $0) } ?? point)
    }

    /// Whether a mouse-down at `point` starts a window drag.
    static func drags(_ window: DragRecordingWindow, at point: NSPoint) throws -> Bool {
        let view = try #require(hit(window, point), "nothing at \(point)")
        let event = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: 0,
                                                    windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                                    clickCount: 1, pressure: 1))
        let before = window.drags
        view.mouseDown(with: event)
        return window.drags > before
    }

    static func center(of view: NSView) -> NSPoint {
        view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
    }

    static func buttons(under view: NSView) -> [NSButton] {
        ((view as? NSButton).map { [$0] } ?? []) + view.subviews.filter { !$0.isHidden }.flatMap(buttons(under:))
    }

    @Test func emptyHeaderSpaceDragsTheWindowAndButtonsStayButtons() async throws {
        let window = DragRecordingWindow(contentRect: NSRect(x: 0, y: 0, width: 948, height: 700), styleMask: [.borderless],
                                         backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let (_, sidebar, transcript) = await HomeTransparencyTests.home(light: false, in: window)
        defer { window.close() }
        let top = window.contentView!.bounds.height

        // People list: the strip above the search field, left of the compose button.
        #expect(try Self.drags(window, at: NSPoint(x: 60, y: top - 20)), "a drag on the list's top strip moves the window")
        #expect(Self.hit(window, Self.center(of: sidebar.compose)) === sidebar.compose, "the compose button takes its click")

        // Transcript: the header, away from the avatar and the name pill.
        #expect(try Self.drags(window, at: NSPoint(x: transcript.frame.minX + 40, y: top - 30)),
                "a drag on the transcript header moves the window")
        let pill = try #require(Self.buttons(under: transcript).first { $0.bezelStyle == .glass && !$0.title.isEmpty },
                                "the header's name pill")
        #expect(Self.hit(window, Self.center(of: pill)) === pill, "the name pill takes its click")
    }
}
