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
        let panel: SidebarPriorityPanelView
        let window: NSWindow
        var actions: [SidebarPriorityAction] = []

        init(entries: [SidebarPriorityEntry] = SidebarPriorityDragTests.entries, height: CGFloat = 400) {
            panel = SidebarPriorityPanelView(frame: NSRect(x: 0, y: 0, width: 240, height: height))
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 240, height: height), styleMask: [.borderless],
                              backing: .buffered, defer: false)
            panel.show(SidebarPriorityPanel(entries: entries))
            window.contentView = panel
            panel.layoutSubtreeIfNeeded()
            panel.onAction = { [unowned self] in actions.append($0) }
        }

        func event(_ type: NSEvent.EventType, at location: NSPoint) throws -> NSEvent {
            try #require(NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: 0,
                                            windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                            clickCount: 1, pressure: 1))
        }

        /// Presses `id`'s row at its middle, moves the pointer by each of `moves` (points, down is
        /// positive) and releases at the last one.
        func press(_ id: String, moves: [CGFloat]) throws {
            let row = try #require(panel.rows[id])
            let start = row.convert(NSPoint(x: 10, y: row.bounds.midY), to: nil)
            // Window points grow up; the panel's rows lay out top down.
            func at(_ dy: CGFloat) -> NSPoint { NSPoint(x: start.x, y: start.y - dy) }
            row.mouseDown(with: try event(.leftMouseDown, at: at(0)))
            for dy in moves { row.mouseDragged(with: try event(.leftMouseDragged, at: at(dy))) }
            row.mouseUp(with: try event(.leftMouseUp, at: at(moves.last ?? 0)))
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

    @Test func rowHitTestingTargetsTheRowForDragPresses() throws {
        let harness = Harness()
        let row = try #require(harness.panel.rows["b"])
        // FlippedDocument forwards its document-space point to the row. A non-top row must
        // convert that point before checking its local bounds.
        #expect(row.hitTest(NSPoint(x: row.frame.midX, y: row.frame.midY)) === row)
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

    /// An overflowing list: a row held at the bottom edge scrolls the list (edge autoscroll), and the
    /// drop reads the pointer through the scrolled clip view, so the row lands past rows that were
    /// off-screen when the drag began. The drop stops the autoscroll.
    @Test func aRowHeldAtTheBottomEdgeScrollsTheListAndDropsPastHiddenRows() throws {
        let entries = (0..<30).map { SidebarPriorityEntry(id: "r\($0)", title: "r\($0)", state: .idle) }
        let harness = Harness(entries: entries, height: 200)
        let panel = harness.panel
        let row = try #require(panel.rows["r0"])
        let clip = try #require(row.enclosingScrollView?.contentView)
        let shownAtStart = clip.bounds
        try #require(shownAtStart.height > 0 && panel.rows.count == 30)
        let framesAtStart = panel.rows.mapValues(\.frame)
        try #require(framesAtStart.values.contains { $0.minY >= shownAtStart.maxY }, "the list does not overflow")

        let start = row.convert(NSPoint(x: 10, y: row.bounds.midY), to: nil)
        let edge = clip.convert(NSPoint(x: 10, y: shownAtStart.maxY - 2), to: nil)
        row.mouseDown(with: try harness.event(.leftMouseDown, at: start))
        row.mouseDragged(with: try harness.event(.leftMouseDragged, at: NSPoint(x: start.x, y: start.y - 12)))
        row.mouseDragged(with: try harness.event(.leftMouseDragged, at: edge))
        #expect(panel.autoscroll.isActive, "holding the row at the bottom edge started no autoscroll")
        for _ in 0..<10 { _ = panel.autoscrollFrame(elapsed: 1.0 / 30) }
        #expect(clip.bounds.minY > shownAtStart.minY, "the list did not scroll")

        row.mouseUp(with: try harness.event(.leftMouseUp, at: edge))
        #expect(!panel.autoscroll.isActive, "autoscroll kept running after the drop")
        guard case .place("r0", let order)? = harness.actions.last else {
            Issue.record("the drop asked for no place: \(harness.actions)")
            return
        }
        let slot = try #require(order.firstIndex(of: "r0"))
        try #require(slot > 0)
        // The row the dropped one now follows was below the visible rows when the drag began.
        let passed = try #require(framesAtStart[order[slot - 1]])
        #expect(passed.minY >= shownAtStart.maxY, "dropped at slot \(slot), within the rows shown at the start")
        #expect(!panel.autoscrollFrame(elapsed: 1.0 / 30), "an autoscroll frame ran with no drag")
    }

    /// A feed update while a row is held still mid-drag (away from the edges) re-ranks the others, but the
    /// dragged row stays under the pointer, and the drop reads the slot from the updated feed.
    @Test func aFeedUpdateMidDragKeepsTheDraggedRowUnderThePointer() throws {
        let harness = Harness()
        let panel = harness.panel
        let row = try #require(panel.rows["a"])
        let height = row.frame.height
        let start = row.convert(NSPoint(x: 10, y: row.bounds.midY), to: nil)
        let held = NSPoint(x: start.x, y: start.y - height * 1.1)
        row.mouseDown(with: try harness.event(.leftMouseDown, at: start))
        row.mouseDragged(with: try harness.event(.leftMouseDragged, at: NSPoint(x: start.x, y: start.y - height * 0.4)))
        row.mouseDragged(with: try harness.event(.leftMouseDragged, at: held))
        let draggedFrame = row.frame
        #expect(abs(draggedFrame.minY - height * 1.1) < 0.5, "the row does not follow the pointer: \(draggedFrame)")

        let byID = Dictionary(uniqueKeysWithValues: Self.entries.map { ($0.id, $0) })
        panel.show(SidebarPriorityPanel(entries: ["a", "c", "b"].compactMap { byID[$0] }))
        #expect(row.frame == draggedFrame, "a feed update moved the held row from \(draggedFrame) to \(row.frame)")

        // Its middle is past c's (now second) middle and short of b's: it drops second.
        row.mouseUp(with: try harness.event(.leftMouseUp, at: held))
        #expect(harness.actions == [.place("a", order: ["c", "a", "b"])])
    }

    /// The dragged chat leaves the feed mid-drag (autoscroll running): the drag ends there, the autoscroll
    /// stops, and the release asks for nothing.
    @Test func theDraggedChatLeavingTheFeedCancelsTheDrag() throws {
        let entries = (0..<30).map { SidebarPriorityEntry(id: "r\($0)", title: "r\($0)", state: .idle) }
        let harness = Harness(entries: entries, height: 200)
        let panel = harness.panel
        let row = try #require(panel.rows["r0"])
        let clip = try #require(row.enclosingScrollView?.contentView)
        let start = row.convert(NSPoint(x: 10, y: row.bounds.midY), to: nil)
        let edge = clip.convert(NSPoint(x: 10, y: clip.bounds.maxY - 2), to: nil)
        row.mouseDown(with: try harness.event(.leftMouseDown, at: start))
        row.mouseDragged(with: try harness.event(.leftMouseDragged, at: NSPoint(x: start.x, y: start.y - 12)))
        row.mouseDragged(with: try harness.event(.leftMouseDragged, at: edge))
        try #require(panel.autoscroll.isActive, "holding the row at the bottom edge started no autoscroll")

        panel.show(SidebarPriorityPanel(entries: Array(entries.dropFirst())))
        #expect(panel.rows["r0"] == nil)
        #expect(!panel.autoscroll.isActive, "autoscroll kept running for a chat that left")
        #expect(!panel.autoscrollFrame(elapsed: 1.0 / 30), "an autoscroll frame ran after the drag ended")
        row.mouseDragged(with: try harness.event(.leftMouseDragged, at: edge))
        row.mouseUp(with: try harness.event(.leftMouseUp, at: edge))
        #expect(harness.actions.isEmpty, "the release of a chat that left asked for \(harness.actions)")
        #expect(!panel.autoscroll.isActive)
    }

    /// The panel leaves its window mid-drag (autoscroll running) and comes back: the drag is over. No row is
    /// left lifted or displaced, the autoscroll is off, and the press's late release opens and moves nothing.
    @Test func leavingTheWindowMidDragEndsTheDrag() throws {
        let entries = (0..<30).map { SidebarPriorityEntry(id: "r\($0)", title: "r\($0)", state: .idle) }
        let harness = Harness(entries: entries, height: 200)
        let panel = harness.panel
        let ranked = panel.rows.mapValues(\.frame)
        let row = try #require(panel.rows["r0"])
        let clip = try #require(row.enclosingScrollView?.contentView)
        let start = row.convert(NSPoint(x: 10, y: row.bounds.midY), to: nil)
        let edge = clip.convert(NSPoint(x: 10, y: clip.bounds.maxY - 2), to: nil)
        row.mouseDown(with: try harness.event(.leftMouseDown, at: start))
        row.mouseDragged(with: try harness.event(.leftMouseDragged, at: NSPoint(x: start.x, y: start.y - 12)))
        row.mouseDragged(with: try harness.event(.leftMouseDragged, at: edge))
        try #require(panel.isDraggingRow && panel.autoscroll.isActive, "the drag or its autoscroll did not start")
        try #require(row.frame != ranked["r0"], "the dragged row did not move")

        harness.window.contentView = NSView()
        #expect(!panel.isDraggingRow, "the drag outlived the window")
        #expect(!panel.autoscroll.isActive, "autoscroll kept running out of the window")
        harness.window.contentView = panel
        panel.layoutSubtreeIfNeeded()
        #expect(!panel.isDraggingRow)
        #expect(!panel.autoscroll.isActive)
        #expect(row.layer?.zPosition ?? 0 == 0, "the row stayed lifted")
        for (id, frame) in ranked {
            #expect(panel.rows[id]?.frame == frame, "\(id) is displaced: \(String(describing: panel.rows[id]?.frame)) for \(frame)")
        }

        row.mouseUp(with: try harness.event(.leftMouseUp, at: edge))
        #expect(harness.actions.isEmpty, "the late release asked for \(harness.actions)")
        #expect(panel.panel.entries.map(\.id) == entries.map(\.id))
    }
}
