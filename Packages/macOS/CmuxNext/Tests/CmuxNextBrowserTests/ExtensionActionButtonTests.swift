import AppKit
@testable import CmuxNextBrowser
import Testing

/// An extension action's press, drag and release from the button's own mouse events: before,
/// `mouseDown` ran a `nextEvent(matching:)` loop that held the main thread until the release. A click runs the
/// action, a release outside takes it back, and a horizontal drag past 3 pt reorders the pinned buttons.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1)))
struct ExtensionActionButtonTests {
    @MainActor private final class Harness {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 100), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        let button = ExtensionActionButton(actionID: "ext")
        var runs = 0
        var moves: [CGFloat] = []
        var ends: [CGFloat] = []
        var dragAllowed = true

        init() {
            _ = NSApplication.shared
            window.isReleasedWhenClosed = false
            let content = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 100))
            window.contentView = content
            content.addSubview(button)
            // Framed at its own size, 100 pt in and 20 pt down, as the toolbar's row places it.
            let size = button.intrinsicContentSize
            button.frame = NSRect(x: 100, y: content.bounds.height - 20 - size.height, width: size.width, height: size.height)
            button.onRun = { [unowned self] in runs += 1 }
            button.canDrag = { [unowned self] in dragAllowed }
            button.onDragMoved = { [unowned self] in moves.append($0) }
            button.onDragEnded = { [unowned self] in ends.append($0) }
        }

        /// The button's center moved by `dx`, `dy`, in window coordinates.
        func point(dx: CGFloat = 0, dy: CGFloat = 0) -> NSPoint {
            let center = button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil)
            return NSPoint(x: center.x + dx, y: center.y + dy)
        }

        func event(_ type: NSEvent.EventType, dx: CGFloat = 0, dy: CGFloat = 0) throws -> NSEvent {
            try #require(NSEvent.mouseEvent(with: type, location: point(dx: dx, dy: dy), modifierFlags: [], timestamp: 0,
                                            windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                            clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1))
        }
    }

    /// The button is the toolbar's square by its intrinsic size, with no constraint of
    /// its own, so the toolbar's row frames it and a pane resized every frame solves none for it.
    @Test func theButtonIsTheToolbarSquareWithoutConstraints() {
        let h = Harness()
        defer { h.window.close() }
        let side = OmnibarStyle.buttonSize
        #expect(h.button.intrinsicContentSize == NSSize(width: side, height: side))
        #expect(h.button.frame.size == NSSize(width: side, height: side))
        #expect(OmnibarBadgeFrameLayoutTests.usesFrames(h.button))
        #expect(h.button.translatesAutoresizingMaskIntoConstraints)
    }

    /// The press lights the button and returns at once; the release over it runs the action once.
    @Test func aClickRunsTheActionOnRelease() throws {
        let h = Harness()
        defer { h.window.close() }
        #expect(h.button.bounds.width > 0)
        h.button.mouseDown(with: try h.event(.leftMouseDown))
        #expect(h.button.isHighlighted, "the press did not show")
        #expect(h.runs == 0, "the press ran the action before its release")
        h.button.mouseUp(with: try h.event(.leftMouseUp, dx: 1))
        #expect(h.runs == 1)
        #expect(!h.button.isHighlighted)
        #expect(h.moves.isEmpty && h.ends.isEmpty)
    }

    /// Dragged out (vertically, so no reorder) and released outside: nothing runs.
    @Test func aReleaseOutsideTakesThePressBack() throws {
        let h = Harness()
        defer { h.window.close() }
        h.button.mouseDown(with: try h.event(.leftMouseDown))
        h.button.mouseDragged(with: try h.event(.leftMouseDragged, dy: 60))
        h.button.mouseUp(with: try h.event(.leftMouseUp, dy: 60))
        #expect(h.runs == 0)
        #expect(h.moves.isEmpty && h.ends.isEmpty)
        #expect(!h.button.isHighlighted)
    }

    /// A horizontal drag past 3 pt becomes a reorder: each step reports its offset, the release reports
    /// where it ended, and the action does not run.
    @Test func aHorizontalDragReorders() throws {
        let h = Harness()
        defer { h.window.close() }
        h.button.mouseDown(with: try h.event(.leftMouseDown))
        h.button.mouseDragged(with: try h.event(.leftMouseDragged, dx: 2))
        #expect(h.moves.isEmpty, "a drag within 3 pt moved the button")
        #expect(h.button.isHighlighted)
        h.button.mouseDragged(with: try h.event(.leftMouseDragged, dx: 8))
        h.button.mouseDragged(with: try h.event(.leftMouseDragged, dx: 20))
        #expect(h.moves == [8, 20])
        #expect(!h.button.isHighlighted, "a reorder drag kept the pressed fill")
        h.button.mouseUp(with: try h.event(.leftMouseUp, dx: 24))
        #expect(h.ends == [24])
        #expect(h.runs == 0)
    }

    /// With no pinned order to change, a horizontal drag is still a click: the release over the button runs it.
    @Test func aDragThatMayNotReorderStaysAClick() throws {
        let h = Harness()
        defer { h.window.close() }
        h.dragAllowed = false
        h.button.mouseDown(with: try h.event(.leftMouseDown))
        h.button.mouseDragged(with: try h.event(.leftMouseDragged, dx: 6))
        h.button.mouseUp(with: try h.event(.leftMouseUp, dx: 6))
        #expect(h.moves.isEmpty && h.ends.isEmpty)
        #expect(h.runs == 1)
    }

    /// The button leaves its window under a held press: the press ends, and a stray release runs nothing.
    @Test func aPressEndsWhenTheButtonLeavesItsWindow() throws {
        let h = Harness()
        defer { h.window.close() }
        let release = try h.event(.leftMouseUp)
        h.button.mouseDown(with: try h.event(.leftMouseDown))
        h.button.removeFromSuperview()
        #expect(!h.button.isHighlighted)
        h.button.mouseUp(with: release)
        #expect(h.runs == 0)
        #expect(h.moves.isEmpty && h.ends.isEmpty, "a plain press reported a drag")
    }

    /// The button leaves its window during a reorder drag (a render unpins or removes it): the drag ends once
    /// at offset 0, the start index, so the toolbar clears every shift and reorders nothing; a stray release
    /// reports nothing more.
    @Test func aReorderDragEndsAtItsStartWhenTheButtonLeavesItsWindow() throws {
        let h = Harness()
        defer { h.window.close() }
        let release = try h.event(.leftMouseUp, dx: 24)
        h.button.mouseDown(with: try h.event(.leftMouseDown))
        h.button.mouseDragged(with: try h.event(.leftMouseDragged, dx: ExtensionActionButton.dragThreshold + 17))
        #expect(h.moves == [ExtensionActionButton.dragThreshold + 17])
        h.button.removeFromSuperview()
        #expect(h.ends == [0], "the drag did not end at its start index")
        h.button.mouseUp(with: release)
        #expect(h.ends == [0], "the stray release ended the drag again")
        #expect(h.runs == 0)
    }
}
