import AppKit
@testable import CmuxNextSidebar
import Testing

/// A Priority row the person drags past the drag threshold moves to where they drop it and asks the
/// App to keep it there (`SidebarPriorityAction.place`); a click, jitter included, still opens the
/// chat (Leo 2026-10-21: "the click and drag doesn't quite work for moving guys up").
@MainActor
struct SidebarPriorityDragTests {
    static let entries = ["a", "b", "c"].map { SidebarPriorityEntry(id: $0, title: $0, state: .idle) }

    /// The panel in a window, its rows laid out at once (shown before the window, so nothing glides).
    final class Harness {
        let panel = SidebarPriorityPanelView(frame: NSRect(x: 0, y: 0, width: 240, height: 400))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 240, height: 400), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        var actions: [SidebarPriorityAction] = []

        init() {
            panel.show(SidebarPriorityPanel(entries: SidebarPriorityDragTests.entries))
            window.contentView = panel
            panel.layoutSubtreeIfNeeded()
            panel.onAction = { [unowned self] in actions.append($0) }
        }

        /// Presses `id`'s row at its middle, moves the pointer by each of `moves` (points, down is
        /// positive) and releases at the last one.
        func press(_ id: String, moves: [CGFloat]) throws {
            let row = try #require(panel.rows[id])
            let start = row.convert(NSPoint(x: 10, y: row.bounds.midY), to: nil)
            func event(_ type: NSEvent.EventType, _ dy: CGFloat) throws -> NSEvent {
                // Window points grow up; the panel's rows lay out top down.
                try #require(NSEvent.mouseEvent(with: type, location: NSPoint(x: start.x, y: start.y - dy), modifierFlags: [],
                                                timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                                eventNumber: 0, clickCount: 1, pressure: 1))
            }
            row.mouseDown(with: try event(.leftMouseDown, 0))
            for dy in moves { row.mouseDragged(with: try event(.leftMouseDragged, dy)) }
            row.mouseUp(with: try event(.leftMouseUp, moves.last ?? 0))
        }
    }

    @Test func draggingARowUpPlacesItWhereItDrops() throws {
        let harness = Harness()
        let height = try #require(harness.panel.rows["c"]).frame.height
        try harness.press("c", moves: [-3, -height, -2.2 * height])
        #expect(harness.actions == [.place("c", order: ["c", "a", "b"])])
        // The rows show the dropped order at once, before the App's ranking comes back with it.
        #expect(harness.panel.panel.entries.map(\.id) == ["c", "a", "b"])
    }

    @Test func draggingARowDownOneSlotPlacesItThere() throws {
        let harness = Harness()
        let height = try #require(harness.panel.rows["a"]).frame.height
        try harness.press("a", moves: [height * 0.4, height * 1.1])
        #expect(harness.actions == [.place("a", order: ["b", "a", "c"])])
    }

    @Test func aClickWithJitterOpensTheChatAndMovesNothing() throws {
        let harness = Harness()
        try harness.press("b", moves: [3])
        try harness.press("a", moves: [])
        #expect(harness.actions == [.open("b"), .open("a")])
        #expect(harness.panel.panel.entries.map(\.id) == ["a", "b", "c"])
    }

    @Test func aDropBackInItsOwnPlaceAsksForNothing() throws {
        let harness = Harness()
        let height = try #require(harness.panel.rows["b"]).frame.height
        try harness.press("b", moves: [-height * 0.3, 0])
        #expect(harness.actions.isEmpty)
    }
}
