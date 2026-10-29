import AppKit
@testable import CmuxNextDesign
import CmuxNextInput
@testable import CmuxNextSidebar
import Testing

/// Sidebar hover once per frame (feature `pointerFrameHover`) on p04-input-030's
/// `FrameInputCoalescer`, as Chromium delivers rAF-aligned moves (main_thread_event_queue.cc): the
/// first move of a frame interval hovers in its own turn, the rest of the interval once at the frame,
/// at the latest point. Enter, exit and a press are discrete: they land the pending moves first, so a
/// click after fast moves acts on the row under its own point. The list, the space bar and the rail.
@MainActor @Suite(.serialized) struct SidebarHoverTests {
    @MainActor final class Harness {
        let list: SidebarListView
        let window: NSWindow
        let frames = PointerFrameTestRig()
        let rows: [SidebarRow]
        /// Every hovered row the list showed, in order (one entry per hover change).
        var hoverChanges: [SidebarRowKey?] = []
        private var lastHovered: SidebarRowKey?

        init(frameInput: Bool = true) throws {
            _ = NSApplication.shared
            let titles = ["one", "two", "three", "four", "five", "six"]
            let workspaces = titles.enumerated().map { SidebarWorkspace(id: WorkspaceID("ws-\($0.offset)"), title: $0.element) }
            let machine = SidebarMachine(id: .local, name: "This Mac", kind: .local)
            let model = SidebarModel(sections: [SidebarSection(kind: .machine(machine), nodes: workspaces.map { .workspace($0) })],
                                     activeWorkspaceID: WorkspaceID("ws-0"))
            list = SidebarListView(model: model)
            window = SidebarHoverTests.window(width: 240, height: 600)
            window.contentView = list
            list.frame = NSRect(x: 0, y: 0, width: 240, height: 600)
            list.reload(animated: false)
            rows = list.displayed.rows.filter { if case .workspace = $0.key { true } else { false } }
            if frameInput { list.hoverFrameInput = frames.coalescers }
            try #require(rows.count == titles.count)
        }

        /// The window point in the middle of row `index`.
        func point(_ index: Int) -> NSPoint {
            let row = rows[index]
            return list.convert(NSPoint(x: list.bounds.midX, y: row.y + row.height / 2), to: nil)
        }

        func event(_ type: NSEvent.EventType, row index: Int) throws -> NSEvent {
            try SidebarHoverTests.mouse(type, at: point(index), in: window)
        }

        func move(to index: Int) throws {
            list.mouseMoved(with: try event(.mouseMoved, row: index))
            record()
        }

        func frame() {
            frames.frame()
            record()
        }

        func record() {
            guard list.hoveredKey != lastHovered else { return }
            lastHovered = list.hoveredKey
            hoverChanges.append(lastHovered)
        }

        func close() {
            frames.close()
            window.close()
        }
    }

    static func window(width: CGFloat, height: CGFloat) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: width, height: height), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        return window
    }

    static func mouse(_ type: NSEvent.EventType, at point: CGPoint, in window: NSWindow) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                        windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                                        pressure: type == .leftMouseUp ? 0 : 1))
    }

    static func exit(at point: CGPoint, in window: NSWindow) throws -> NSEvent {
        try #require(NSEvent.enterExitEvent(with: .mouseExited, location: point, modifierFlags: [], timestamp: 0,
                                            windowNumber: window.windowNumber, context: nil, eventNumber: 0, trackingNumber: 0,
                                            userData: nil))
    }

    // MARK: The list

    /// A lone move after an idle frame hovers in the same turn: the frame-aligned path adds no wait.
    @Test func aSingleMoveAfterAnIdleFrameHoversInTheSameTurn() throws {
        let harness = try Harness()
        defer { harness.close() }
        try harness.move(to: 2)
        #expect(harness.hoverChanges == [harness.rows[2].key])
        #expect(!harness.frames.coalescer.hasPending, "nothing waits for the frame")
    }

    /// Eight moves down the list in one frame: the first hovers at once, the other seven once at the
    /// frame, the row under the last move. Two hovers, no more.
    @Test func eightMovesInOneFrameHoverTwiceTheLeadingAndTheLatestRow() throws {
        let harness = try Harness()
        defer { harness.close() }
        for step in 0..<8 { try harness.move(to: step % harness.rows.count) }
        #expect(harness.hoverChanges == [harness.rows[0].key], "before the frame only the leading move hovered")
        #expect(harness.frames.coalescer.hasPending)
        harness.frame()
        #expect(harness.hoverChanges == [harness.rows[0].key, harness.rows[7 % harness.rows.count].key])
        #expect(harness.list.frameInputHover.maxDeliveriesPerFrame == 2)
        #expect(!harness.frames.coalescer.hasPending)
    }

    /// A press after fast moves acts on the row under the press: the pending moves land first, and
    /// the hover the press reads is the row it is on, not a stale one.
    @Test func aClickAfterFastMovesHitsTheRowUnderTheClick() throws {
        let harness = try Harness()
        defer { harness.close() }
        try harness.move(to: 1)
        harness.frame()
        for index in [2, 3, 4] { try harness.move(to: index) }
        #expect(harness.list.hoveredKey == harness.rows[2].key, "the interval's leading move hovered; 3 and 4 wait")
        #expect(harness.frames.coalescer.hasPending)
        harness.list.mouseDown(with: try harness.event(.leftMouseDown, row: 4))
        #expect(!harness.frames.coalescer.hasPending, "the press left moves for a later frame")
        harness.list.mouseUp(with: try harness.event(.leftMouseUp, row: 4))
        #expect(harness.list.model.selection == [WorkspaceID("ws-4")])
    }

    /// Leaving the list lands the pending moves before it clears the hover: a frame that comes after
    /// the exit lights no row.
    @Test func anExitFlushesThePendingMovesThenClearsTheHover() throws {
        let harness = try Harness()
        defer { harness.close() }
        try harness.move(to: 2)
        try harness.move(to: 3)
        #expect(harness.frames.coalescer.hasPending)
        harness.list.mouseExited(with: try SidebarHoverTests.exit(at: harness.point(3), in: harness.window))
        harness.record()
        #expect(!harness.frames.coalescer.hasPending, "the exit landed the pending move")
        #expect(harness.list.hoveredKey == nil)
        harness.frame()
        #expect(harness.list.hoveredKey == nil, "a move delivered after the exit lit a row")
    }

    /// A move still waiting when the list leaves its window hovers nothing at the frame.
    @Test func aMoveDeliveredAfterTheListLeftItsWindowHoversNothing() throws {
        let harness = try Harness()
        defer { harness.close() }
        try harness.move(to: 1)
        try harness.move(to: 4)
        harness.window.contentView = nil
        harness.frame()
        #expect(harness.hoverChanges == [harness.rows[1].key])
    }

    /// With the feature off (no frame-aligned input), every move hovers at once.
    @Test func withoutFrameInputEveryMoveHovers() throws {
        let harness = try Harness(frameInput: false)
        defer { harness.close() }
        for index in 0..<4 { try harness.move(to: index) }
        #expect(harness.hoverChanges == (0..<4).map { Optional(harness.rows[$0].key) })
        #expect(!harness.frames.coalescer.hasPending)
    }

    // MARK: The space bar

    /// The space bar: a lone move hovers at once, a frame's later moves once at the frame (the latest
    /// space), and a press lands them first.
    @Test func theSpaceBarHoversOnTheLeadingEdgeAndOnceAtTheFrame() throws {
        _ = NSApplication.shared
        let frames = PointerFrameTestRig()
        defer { frames.close() }
        let model = SidebarModel()
        model.profiles = (0..<4).map { SidebarProfile(id: ProfileKey("space-\($0)"), name: "Space \($0)", color: .blue) }
        model.activeProfileID = model.profiles[0].id
        let bar = ProfileBarView(model: model)
        let window = Self.window(width: 240, height: 28)
        defer { window.close() }
        window.contentView = bar
        bar.frame = NSRect(x: 0, y: 0, width: 240, height: 28)
        bar.layoutSubtreeIfNeeded()
        bar.refresh()
        bar.hoverFrameInput = frames.coalescers
        let slots = bar.slotRects()
        func move(to index: Int) throws {
            let point = bar.convert(CGPoint(x: slots[index].midX, y: slots[index].midY), to: nil)
            bar.mouseMoved(with: try Self.mouse(.mouseMoved, at: point, in: window))
        }

        try move(to: 1)
        #expect(bar.hovered == 1, "the lone move hovered in its own turn")
        for index in [2, 3, 0, 2] { try move(to: index) }
        #expect(bar.hovered == 1, "the interval's later moves wait for the frame")
        frames.frame()
        #expect(bar.hovered == 2, "the frame hovered the latest space")
        #expect(bar.frameInputHover.maxDeliveriesPerFrame == 2)

        try move(to: 0)
        try move(to: 3)
        #expect(bar.hovered == 0)
        let press = bar.convert(CGPoint(x: slots[3].midX, y: slots[3].midY), to: nil)
        bar.mouseDown(with: try Self.mouse(.leftMouseDown, at: press, in: window))
        #expect(bar.hovered == 3, "the press landed the pending move first")
        #expect(!frames.coalescer.hasPending)
    }

    // MARK: The rail

    /// The rail's hover cards follow a frame interval's leading move at once and its later moves once at
    /// the frame; an exit lands them first.
    @Test func theRailTellsItsCardsOnTheLeadingEdgeAndOnceAtTheFrame() throws {
        _ = NSApplication.shared
        let frames = PointerFrameTestRig()
        defer { frames.close() }
        let rail = SidebarRailView()
        let window = Self.window(width: 12, height: 600)
        defer { window.close() }
        window.contentView = rail
        rail.frame = NSRect(x: 0, y: 0, width: 12, height: 600)
        let cards = SidebarRailHoverCards()
        var told = 0
        // Each pointer report to the cards asks for the coordinator once.
        cards.coordinator = {
            told += 1
            return nil
        }
        rail.cards = cards
        rail.hoverFrameInput = frames.coalescers
        func move(_ y: CGFloat) throws {
            rail.mouseMoved(with: try Self.mouse(.mouseMoved, at: CGPoint(x: 6, y: y), in: window))
        }

        try move(100)
        #expect(told == 1, "the lone move reached the cards in its own turn")
        for y in stride(from: 110, through: 170, by: 10) { try move(CGFloat(y)) }
        #expect(told == 1, "the interval's later moves wait for the frame")
        frames.frame()
        #expect(told == 2, "the frame told the cards once, at the latest point")
        try move(200)
        try move(210)
        #expect(told == 3)
        rail.mouseExited(with: try Self.exit(at: CGPoint(x: 6, y: 210), in: window))
        #expect(told == 5, "the exit landed the pending move, then told the cards the pointer left")
        #expect(!frames.coalescer.hasPending)
    }
}
