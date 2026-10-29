import AppKit
import CmuxNextDesign
@testable import CmuxNextSidebar
import Testing

/// A Priority row the person drags past the drag threshold moves to where they drop it and asks the
/// App to keep it there (`SidebarPriorityAction.place`); a click, jitter included, still opens the
/// chat (Leo 2026-10-21: "the click and drag doesn't quite work for moving guys up").
@MainActor @Suite(.serialized)
struct SidebarPriorityDragTests {
    static let entries = ["a", "b", "c"].map { SidebarPriorityEntry(id: $0, title: $0, state: .idle) }

    /// The panel in a window, its rows laid out at once (shown before the window, so nothing glides).
    final class Harness {
        let panel: SidebarPriorityPanelView
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 240, height: 400), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        var actions: [SidebarPriorityAction] = []
        private var pressOrigins: [String: NSPoint] = [:]
        private let previousReduceMotion = Motion.reduceMotionOverride

        init(entries: [SidebarPriorityEntry] = SidebarPriorityDragTests.entries, sidebar: SidebarView? = nil) {
            _ = NSApplication.shared
            // These synchronous tests inspect cancellation's destination, not intermediate motion frames.
            Motion.reduceMotionOverride = true
            window.isReleasedWhenClosed = false
            panel = sidebar?.priorityPanelView ?? SidebarPriorityPanelView(frame: NSRect(x: 0, y: 0, width: 240, height: 400))
            if let sidebar {
                sidebar.frame = NSRect(x: 0, y: 0, width: 240, height: 400)
                sidebar.showPriority(SidebarPriorityPanel(entries: entries, shown: true))
                window.contentView = sidebar
                sidebar.layoutSubtreeIfNeeded()
            } else {
                panel.show(SidebarPriorityPanel(entries: entries))
                window.contentView = panel
            }
            panel.layoutSubtreeIfNeeded()
            panel.onAction = { [weak self] in self?.actions.append($0) }
        }

        func close() {
            window.contentView = nil
            window.close()
            Motion.reduceMotionOverride = previousReduceMotion
        }

        func event(_ type: NSEvent.EventType, on id: String, dy: CGFloat = 0) throws -> NSEvent {
            let row = try #require(panel.rows[id])
            if type == .leftMouseDown {
                pressOrigins[id] = row.convert(NSPoint(x: 10, y: row.bounds.midY), to: nil)
            }
            let start = try #require(pressOrigins[id])
            // Keep the original window point even as the dragged row moves under the pointer.
            return try #require(NSEvent.mouseEvent(with: type, location: NSPoint(x: start.x, y: start.y - dy), modifierFlags: [],
                                                  timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                                  eventNumber: 0, clickCount: 1, pressure: 1))
        }

        func escape(in target: NSWindow) throws {
            let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                     windowNumber: target.windowNumber, context: nil, characters: "\u{1b}",
                                                     charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
            NSApplication.shared.sendEvent(event)
        }

        /// Presses `id`'s row at its middle, moves the pointer by each of `moves` (points, down is
        /// positive) and releases at the last one.
        func press(_ id: String, moves: [CGFloat]) throws {
            let row = try #require(panel.rows[id])
            row.mouseDown(with: try event(.leftMouseDown, on: id))
            for dy in moves { row.mouseDragged(with: try event(.leftMouseDragged, on: id, dy: dy)) }
            row.mouseUp(with: try event(.leftMouseUp, on: id, dy: moves.last ?? 0))
        }
    }

    @Test func draggingARowUpPlacesItWhereItDrops() throws {
        let harness = Harness()
        defer { harness.close() }
        let height = try #require(harness.panel.rows["c"]).frame.height
        try harness.press("c", moves: [-3, -height, -2.2 * height])
        #expect(harness.actions == [.place("c", order: ["c", "a", "b"])])
        // The rows show the dropped order at once, before the App's ranking comes back with it.
        #expect(harness.panel.panel.entries.map(\.id) == ["c", "a", "b"])
    }

    @Test func draggingARowDownOneSlotPlacesItThere() throws {
        let harness = Harness()
        defer { harness.close() }
        let height = try #require(harness.panel.rows["a"]).frame.height
        try harness.press("a", moves: [height * 0.4, height * 1.1])
        #expect(harness.actions == [.place("a", order: ["b", "a", "c"])])
    }

    @Test func aClickWithJitterOpensTheChatAndMovesNothing() throws {
        let harness = Harness()
        defer { harness.close() }
        try harness.press("b", moves: [3])
        try harness.press("a", moves: [])
        #expect(harness.actions == [.open("b"), .open("a")])
        #expect(harness.panel.panel.entries.map(\.id) == ["a", "b", "c"])
    }

    @Test func aDropBackInItsOwnPlaceAsksForNothing() throws {
        let harness = Harness()
        defer { harness.close() }
        let height = try #require(harness.panel.rows["b"]).frame.height
        try harness.press("b", moves: [-height * 0.3, 0])
        #expect(harness.actions.isEmpty)
    }

    @Test func hidingAttentionRowsEndsTheDragAndItsStaleReleaseDoesNothing() throws {
        let entries = Self.entries.map { var entry = $0; entry.state = .needsYou; return entry }
        let sidebar = SidebarView(model: SidebarModel(sections: []), design: DesignSettings())
        let harness = Harness(entries: entries, sidebar: sidebar)
        defer { harness.close() }
        let row = try #require(harness.panel.rows["c"])
        let originalTop = row.frame.minY
        let height = row.frame.height
        row.mouseDown(with: try harness.event(.leftMouseDown, on: "c"))
        row.mouseDragged(with: try harness.event(.leftMouseDragged, on: "c", dy: -height))
        #expect(harness.panel.draggingID == "c")
        #expect(row.frame.minY != originalTop)

        // Hidden Priority keeps all attention rows: only shown changes, never the IDs or geometry.
        sidebar.showPriority(SidebarPriorityPanel(entries: entries.filter(\.needsAttention), shown: false))
        #expect(harness.panel.isHidden)
        #expect(harness.panel.panel.entries.map(\.id) == entries.map(\.id))
        #expect(harness.panel.draggingID == nil)
        #expect(row.layer?.zPosition == 0)
        #expect(row.frame.minY == originalTop)

        // The release missed the hidden row. Revealing it and delivering a stale release must do nothing.
        sidebar.showPriority(SidebarPriorityPanel(entries: entries, shown: true))
        #expect(!harness.panel.isHidden)
        #expect(harness.panel.draggingID == nil)
        row.mouseUp(with: try harness.event(.leftMouseUp, on: "c", dy: -height))
        #expect(harness.actions.isEmpty, "a stale release must neither place nor open the chat")
        #expect(harness.panel.panel.entries.map(\.id) == entries.map(\.id))
    }

    @Test(arguments: [false, true], [CGFloat(0), CGFloat(3)])
    func hidingOrRerankingBeforeTheDragThresholdCancelsThePress(hide: Bool, jitter: CGFloat) throws {
        let entries = Self.entries.map { var entry = $0; entry.state = .needsYou; return entry }
        let sidebar = SidebarView(model: SidebarModel(sections: []), design: DesignSettings())
        let harness = Harness(entries: entries, sidebar: sidebar)
        defer { harness.close() }
        let row = try #require(harness.panel.rows["b"])
        let originalFrame = row.frame
        row.mouseDown(with: try harness.event(.leftMouseDown, on: "b"))
        row.mouseDragged(with: try harness.event(.leftMouseDragged, on: "b", dy: jitter))
        #expect(harness.panel.draggingID == nil, "the press has not crossed the drag threshold")

        let updated = hide ? entries : Array(entries.reversed())
        sidebar.showPriority(SidebarPriorityPanel(entries: updated, shown: !hide))
        #expect(harness.panel.isHidden == hide)
        if hide { sidebar.showPriority(SidebarPriorityPanel(entries: updated, shown: true)) }
        #expect(harness.panel.rows["b"] === row)
        // The middle row keeps its geometry, so the stale release still lands inside it.
        #expect(row.frame == originalFrame)
        row.mouseUp(with: try harness.event(.leftMouseUp, on: "b", dy: jitter))
        #expect(harness.actions.isEmpty, "an invalidated press must neither open nor place a chat")
        #expect(harness.panel.panel.entries.map(\.id) == updated.map(\.id))

        try harness.press("b", moves: [3])
        #expect(harness.actions == [.open("b")], "a fresh click must work after cancellation")
    }

    @Test func anotherChatsTextUpdateKeepsTheHeldRowUnderThePointer() throws {
        let harness = Harness()
        defer { harness.close() }
        let row = try #require(harness.panel.rows["c"])
        let height = row.frame.height
        row.mouseDown(with: try harness.event(.leftMouseDown, on: "c"))
        row.mouseDragged(with: try harness.event(.leftMouseDragged, on: "c", dy: -height))
        let heldTop = row.frame.minY
        #expect(harness.panel.draggingID == "c")

        var entries = Self.entries
        entries[0].title = "Progress from another chat"
        harness.panel.show(SidebarPriorityPanel(entries: entries))
        #expect(harness.panel.draggingID == "c", "a text update does not cancel the drag")
        #expect(row.frame.minY == heldTop, "the held row stays under the pointer")

        row.mouseDragged(with: try harness.event(.leftMouseDragged, on: "c", dy: -2.2 * height))
        row.mouseUp(with: try harness.event(.leftMouseUp, on: "c", dy: -2.2 * height))
        #expect(harness.actions == [.place("c", order: ["c", "a", "b"])])
    }

    @Test func updatingRowContentBeforeTheDragThresholdKeepsTheClick() throws {
        let harness = Harness()
        defer { harness.close() }
        let row = try #require(harness.panel.rows["b"])
        row.mouseDown(with: try harness.event(.leftMouseDown, on: "b"))
        var entries = Self.entries
        entries[1].title = "Updated chat"
        harness.panel.show(SidebarPriorityPanel(entries: entries))
        row.mouseUp(with: try harness.event(.leftMouseUp, on: "b"))
        #expect(harness.actions == [.open("b")])
    }

    @Test(arguments: [false, true])
    func escapeCancelsPriorityDragWithoutPlacingOrOpening(fromChildWindow: Bool) throws {
        let sidebar = SidebarView(model: SidebarModel(sections: []), design: DesignSettings())
        let harness = Harness(sidebar: sidebar)
        defer { harness.close() }
        let other = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100), styleMask: [.borderless],
                             backing: .buffered, defer: false)
        other.isReleasedWhenClosed = false
        defer {
            harness.window.removeChildWindow(other)
            other.close()
        }
        let row = try #require(harness.panel.rows["c"])
        let originalTop = row.frame.minY
        let height = row.frame.height
        row.mouseDown(with: try harness.event(.leftMouseDown, on: "c"))
        row.mouseDragged(with: try harness.event(.leftMouseDragged, on: "c", dy: -height))
        #expect(harness.panel.draggingID == "c")
        // An unrelated window's Escape must not cancel this sidebar's gesture.
        try harness.escape(in: other)
        #expect(harness.panel.draggingID == "c")
        #expect(harness.actions.isEmpty)
        if fromChildWindow { harness.window.addChildWindow(other, ordered: .above) }
        // Dispatch through the app so the list's event monitor and Priority callback must route it.
        try harness.escape(in: fromChildWindow ? other : harness.window)
        #expect(harness.panel.draggingID == nil)
        #expect(row.layer?.zPosition == 0)
        #expect(row.frame.minY == originalTop)
        row.mouseUp(with: try harness.event(.leftMouseUp, on: "c", dy: -height))
        #expect(harness.actions.isEmpty)
        #expect(harness.panel.panel.entries.map(\.id) == Self.entries.map(\.id))
    }
}
