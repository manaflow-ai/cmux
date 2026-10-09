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
        let content = window.contentView
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
        let top = window.contentView.bounds.height

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

    /// The Chief transcript in a split, next to another pane on its right
    /// (Lawrence, 2026-10-08): the whole 80 pt header band drags the
    /// window, left and right of the avatar and the pill, above and below
    /// the pill, up to the pane's right edge. The avatar and the pill take
    /// their clicks (the contact), and a divider over the edge still wins.
    @Test func theWholeHeaderBandDragsInASplitAndTheAvatarAndPillAreButtons() async throws {
        let window = DragRecordingWindow(contentRect: NSRect(x: 0, y: 0, width: 1260, height: 700), styleMask: [.borderless],
                                         backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let (_, _, transcript) = await HomeTransparencyTests.home(light: false, in: window)
        defer { window.close() }
        let content = try #require(window.contentView)
        transcript.frame = NSRect(x: 320, y: 0, width: 600, height: 700)
        let neighbor = NSView(frame: NSRect(x: 924, y: 0, width: 336, height: 700))
        content.addSubview(neighbor)
        // A split divider's hit area reaches 3 pt into the Chief pane, above the panes (ScreenContentView).
        let divider = NSView(frame: NSRect(x: 917, y: 0, width: 10, height: 700))
        content.addSubview(divider)
        content.layoutSubtreeIfNeeded()
        var contact = 0
        transcript.onNamePill = { contact += 1 }
        let top = content.bounds.height
        let pill = try #require(Self.buttons(under: transcript).first { $0.bezelStyle == .glass && !$0.title.isEmpty })
        let pillRect = pill.convert(pill.bounds, to: nil)
        let avatar = try #require(Self.avatar(under: transcript), "the header's avatar")
        let avatarRect = avatar.convert(avatar.bounds, to: nil)

        // Every point of the band but the avatar, the pill and the divider drags the window.
        for x in stride(from: transcript.frame.minX + 4, through: divider.frame.minX - 1, by: 37) {
            for y in stride(from: top - 2, through: top - 78, by: -12) {
                let point = NSPoint(x: x, y: y)
                guard !pillRect.contains(point), !avatarRect.contains(point) else { continue }
                #expect(try Self.drags(window, at: point), "the header band at \(point) does not drag the window")
            }
        }
        // The last points before the divider, at the pane's right edge.
        #expect(try Self.drags(window, at: NSPoint(x: divider.frame.minX - 1, y: top - 40)))

        // The avatar is a button: its click opens the contact and never drags.
        #expect(try !Self.drags(window, at: NSPoint(x: avatarRect.midX, y: avatarRect.midY)), "the avatar drags the window")
        #expect(contact == 1, "the avatar's click does not open the contact")
        // The pill stays a button.
        #expect(Self.hit(window, NSPoint(x: pillRect.midX, y: pillRect.midY)) === pill)
        // The divider over the pane's edge still takes the mouse (it resizes the split).
        #expect(Self.hit(window, NSPoint(x: divider.frame.midX, y: top - 40)) === divider)
    }

    /// The header's avatar (the 40 pt image view at the top of the transcript).
    static func avatar(under view: NSView) -> NSImageView? {
        if let image = view as? NSImageView, image.bounds.width == 40, image.bounds.height == 40 { return image }
        return view.subviews.lazy.compactMap { avatar(under: $0) }.first
    }
}

