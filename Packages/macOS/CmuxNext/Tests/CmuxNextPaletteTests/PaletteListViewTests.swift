import AppKit
@testable import CmuxNextPalette
import CmuxNextWakeupsTestSupport
import Testing

/// Palette hover once per frame (feature `pointerFrameHover`) on p04-input-030's
/// `FrameInputCoalescer`, as Chromium delivers rAF-aligned moves (main_thread_event_queue.cc): the
/// first move of a frame interval hovers in its own turn, the rest of the interval once at the frame,
/// the row under the latest point. An exit and a press land the pending move first; a key does too
/// (the application's `sendEvent` flush), so a keyboard selection stays the one that shows. The
/// result list and the Actions menu.
@MainActor @Suite(.serialized) struct PaletteListViewTests {
    @MainActor final class Harness {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 320), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        let list = PaletteListView(frame: NSRect(x: 0, y: 0, width: 400, height: 320))
        let frames = FrameInputTestRig()
        /// Every pointer hover the list reported, in order (`onPointerMove`).
        var moves: [String?] = []
        var activated: [String] = []

        init(frameInput: Bool = true) {
            _ = NSApplication.shared
            window.isReleasedWhenClosed = false
            window.contentView = list
            let items = (0..<6).map { index in
                PaletteItem(id: "item\(index)", title: "Item \(index)",
                            primary: PaletteCommand(id: "open", title: "Open", symbol: "return", effect: .perform {}))
            }
            list.setSections([PaletteResultSection(section: .results, rows: items.map { PaletteRow(item: $0, highlights: [], score: 0) })])
            list.layoutSubtreeIfNeeded()
            if frameInput { list.hoverFrameInput = frames.coalescers }
            list.onPointerMove = { [unowned self] id in moves.append(id) }
            list.onActivate = { [unowned self] id in activated.append(id) }
        }

        /// The center of row `index` (the results have no header), in window coordinates.
        func point(_ index: Int) -> CGPoint {
            let table = list.resultsTable
            let rect = table.rect(ofRow: index)
            return table.convert(CGPoint(x: rect.midX, y: rect.midY), to: nil)
        }

        func move(to index: Int) throws {
            list.resultsTable.mouseMoved(with: try PaletteListViewTests.mouse(.mouseMoved, at: point(index), in: window))
        }

        func close() {
            frames.close()
            window.close()
        }
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

    // MARK: The result list

    /// A lone move after an idle frame hovers in the same turn: the frame-aligned path adds no wait.
    @Test func aSingleMoveAfterAnIdleFrameHoversInTheSameTurn() throws {
        let harness = Harness()
        defer { harness.close() }
        try harness.move(to: 2)
        #expect(harness.moves == ["item2"])
        #expect(!harness.frames.coalescer.hasPending, "nothing waits for the frame")
    }

    /// Eight moves across the rows in one frame: the first hovers at once, the other seven once at the
    /// frame, the row under the last move. Two hovers, no more.
    @Test func eightMovesInOneFrameHoverTwiceTheLeadingAndTheLatestRow() throws {
        let harness = Harness()
        defer { harness.close() }
        for step in 0..<8 { try harness.move(to: step % 6) }
        #expect(harness.moves == ["item0"], "before the frame only the leading move hovered")
        #expect(harness.frames.coalescer.hasPending)
        harness.frames.frame()
        #expect(harness.moves == ["item0", "item\(7 % 6)"])
        #expect(harness.list.resultsTable.hoverMoves.maxDeliveriesPerFrame == 2)
        #expect(!harness.frames.coalescer.hasPending)
    }

    /// A press after fast moves runs the row under the press, and the frame's pending move lands before
    /// it, not after (a later frame would hover a row the press already left).
    @Test func aPressAfterFastMovesRunsTheRowUnderThePress() throws {
        let harness = Harness()
        defer { harness.close() }
        try harness.move(to: 1)
        try harness.move(to: 3)
        #expect(harness.frames.coalescer.hasPending)
        harness.list.resultsTable.mouseDown(with: try PaletteListViewTests.mouse(.leftMouseDown, at: harness.point(4), in: harness.window))
        #expect(!harness.frames.coalescer.hasPending, "the press left a move for a later frame")
        #expect(harness.moves == ["item1", "item3", "item4"], "the pending move landed first, then the press's row")
        #expect(harness.activated == ["item4"])
        harness.frames.frame()
        #expect(harness.moves.last == "item4", "a frame after the press hovered another row")
    }

    /// Leaving the list lands the pending move before it clears the hover: a frame after the exit
    /// hovers nothing.
    @Test func anExitFlushesThePendingMoveThenClearsTheHover() throws {
        let harness = Harness()
        defer { harness.close() }
        var cleared = 0
        harness.list.onHover = { id in if id == nil { cleared += 1 } }
        try harness.move(to: 2)
        try harness.move(to: 3)
        harness.list.resultsTable.mouseExited(with: try PaletteListViewTests.exit(at: harness.point(3), in: harness.window))
        #expect(harness.moves == ["item2", "item3"], "the exit landed the pending move first")
        #expect(cleared == 1)
        harness.frames.frame()
        #expect(harness.moves == ["item2", "item3"], "a move was delivered after the exit")
    }

    /// A key flushes every window's pending moves before it is dispatched (`FrameInputCoalescers.willDispatch`,
    /// what `CmuxApplication.sendEvent` calls): the keyboard's selection is the last word, and the frame
    /// after it hovers nothing that would take it back.
    @Test func aKeyLandsThePendingMoveBeforeTheKeyboardSelection() throws {
        let harness = Harness()
        defer { harness.close() }
        try harness.move(to: 1)
        try harness.move(to: 3)
        #expect(harness.frames.coalescer.hasPending)
        harness.frames.coalescers.willDispatch(.keyDown)
        #expect(harness.moves == ["item1", "item3"])
        harness.list.setSelection("item5") // the key's selection, at once
        harness.frames.frame()
        #expect(harness.moves == ["item1", "item3"], "a hover that waited for the frame landed after the key")
    }

    /// With the feature off (no frame-aligned input), every move hovers at once.
    @Test func withoutFrameInputEveryMoveHovers() throws {
        let harness = Harness(frameInput: false)
        defer { harness.close() }
        for index in 0..<4 { try harness.move(to: index) }
        #expect(harness.moves == (0..<4).map { "item\($0)" })
        #expect(!harness.frames.coalescer.hasPending)
    }

    // MARK: The Actions menu

    /// The Actions menu's rows share the menu's one consumer: a fast sweep over the rows in one frame,
    /// with every row's exit and enter in AppKit's order, hovers the leading row at once and the row
    /// under the latest point at the frame (row crossings coalesce like moves, as Blink derives its
    /// boundary events from the rAF-aligned move, boundary_event_dispatcher.cc). The pointer leaving
    /// the menu lands the pending move first.
    @Test func theActionsMenuHoversOnTheLeadingEdgeAndOnceAtTheFrame() throws {
        _ = NSApplication.shared
        let frames = FrameInputTestRig()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 400), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer {
            frames.close()
            window.close()
        }
        let menu = PaletteActionsMenuView(frame: NSRect(x: 0, y: 0, width: 300, height: 400))
        window.contentView = menu
        let commands = (0..<5).map { PaletteCommand(id: "c\($0)", title: "Command \($0)", symbol: "return", effect: .perform {}) }
        menu.update(PaletteActionsMenuState(itemID: "item", itemTitle: "Item", commands: commands), alternateID: nil)
        menu.layoutSubtreeIfNeeded()
        menu.hoverFrameInput = frames.coalescers
        var hovered: [Int] = []
        menu.onHover = { hovered.append($0) }
        let rows = Self.menuRows(in: menu)
        try #require(rows.count == 5)
        func center(_ index: Int) -> CGPoint { rows[index].convert(CGPoint(x: rows[index].bounds.midX, y: rows[index].bounds.midY), to: nil) }
        func crossing(_ type: NSEvent.EventType, at point: CGPoint) throws -> NSEvent {
            try #require(NSEvent.enterExitEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                                                windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                                trackingNumber: 0, userData: nil))
        }
        // One move from row `from` onto row `to`, as AppKit delivers it: the old row's exit, the new
        // row's enter, then the move, every one at the new point.
        func sweep(from: Int?, to index: Int) throws {
            let point = center(index)
            if let from, from != index { rows[from].mouseExited(with: try crossing(.mouseExited, at: point)) }
            if from != index { rows[index].mouseEntered(with: try crossing(.mouseEntered, at: point)) }
            rows[index].mouseMoved(with: try Self.mouse(.mouseMoved, at: point, in: window))
        }

        var previous: Int?
        for step in 0..<8 {
            try sweep(from: previous, to: step % 5)
            previous = step % 5
        }
        #expect(hovered == [0], "before the frame only the leading event hovered")
        frames.frame()
        #expect(hovered == [0, 7 % 5], "the frame hovered the row under the latest move")
        #expect(hovered.count <= 2, "more than 2 hover updates in one frame")
        #expect(menu.hoverMoves.maxDeliveriesPerFrame <= 2)

        try sweep(from: previous, to: 1)
        try sweep(from: 1, to: 4)
        #expect(hovered == [0, 2, 1], "the next frame interval's leading event hovers at once")
        menu.mouseExited(with: try crossing(.mouseExited, at: center(4)))
        #expect(hovered == [0, 2, 1, 4], "leaving the menu landed the pending move first")
        frames.frame()
        #expect(hovered.last == 4, "a move was delivered after the exit")
    }

    private static func menuRows(in view: NSView) -> [PaletteMenuRow] {
        view.subviews.flatMap { subview -> [PaletteMenuRow] in
            if let row = subview as? PaletteMenuRow { return [row] }
            return menuRows(in: subview)
        }.sorted { $0.frame.minY < $1.frame.minY }
    }
}
