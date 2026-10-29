import AppKit
@testable import CmuxNextDesign
import CmuxNextWakeupsTestSupport
import Testing

/// Native popup rows hover once per frame (feature `pointerFrameHover`): a page menu's
/// rows (``WebPopupRows``) share the menu's one consumer on p04-input-030's `FrameInputCoalescer`, so a
/// frame interval's first move hovers in its own turn and the rest once at the frame, the row under the
/// latest point (Chromium's rAF-aligned moves, main_thread_event_queue.cc). Crossing into or out of a row
/// coalesces like a move (Blink derives boundary events from those moves, boundary_event_dispatcher.cc);
/// leaving the menu and a press land the pending move first. A row with no consumer acts on every move.
@MainActor @Suite(.serialized) struct PopupRowViewTests {
    @MainActor final class Harness {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 240, height: 260), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        let frames = FrameInputTestRig()
        /// What the rows sent the page, in order.
        @MainActor final class Log {
            var highlights: [String] = []
            var picks: [String] = []
        }
        let log: Log
        let rows: WebPopupRows
        var highlights: [String] { log.highlights }
        var picks: [String] { log.picks }

        init(frameInput: Bool = true) {
            _ = NSApplication.shared
            let log = Log()
            self.log = log
            rows = WebPopupRows(onPick: { log.picks.append($0) }, onHover: { log.highlights.append($0) })
            window.isReleasedWhenClosed = false
            let host = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 260))
            window.contentView = host
            host.addSubview(rows)
            if frameInput { rows.hoverFrameInput = frames.coalescers }
            let items = (0..<5).map { WebPopupHost.Item(id: "i\($0)", label: "Item \($0)", shortcut: nil, checked: false, disabled: false, separator: false) }
            rows.update(items, highlighted: nil)
        }

        var rowViews: [PopupRowView] { rows.subviews.compactMap { $0 as? PopupRowView }.sorted { $0.frame.minY < $1.frame.minY } }

        func center(_ index: Int) -> CGPoint {
            let row = rowViews[index]
            return row.convert(CGPoint(x: row.bounds.midX, y: row.bounds.midY), to: nil)
        }

        func move(over index: Int) throws {
            rowViews[index].mouseMoved(with: try PopupRowViewTests.mouse(.mouseMoved, at: center(index), in: window))
        }

        /// One move from row `from` (nil: from outside the menu) onto row `to`, as AppKit delivers it: the
        /// old row's exit, the new row's enter, then the move, every one at the new point.
        func sweep(from: Int?, to index: Int) throws {
            let point = center(index)
            if let from, from != index {
                rowViews[from].mouseExited(with: try PopupRowViewTests.crossing(.mouseExited, at: point, in: window))
            }
            if from != index {
                rowViews[index].mouseEntered(with: try PopupRowViewTests.crossing(.mouseEntered, at: point, in: window))
            }
            try move(over: index)
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

    static func crossing(_ type: NSEvent.EventType, at point: CGPoint, in window: NSWindow) throws -> NSEvent {
        try #require(NSEvent.enterExitEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                                            windowNumber: window.windowNumber, context: nil, eventNumber: 0, trackingNumber: 0,
                                            userData: nil))
    }

    /// A lone move after an idle frame highlights in the same turn.
    @Test func aSingleMoveAfterAnIdleFrameHighlightsInTheSameTurn() throws {
        let harness = Harness()
        defer { harness.close() }
        try #require(harness.rowViews.count == 5)
        try harness.move(over: 2)
        #expect(harness.highlights == ["i2"])
        #expect(!harness.frames.coalescer.hasPending)
    }

    /// A fast sweep in one frame: eight moves over the rows, with every row's exit and enter in AppKit's
    /// order. The leading event highlights at once and the row under the last move at the frame: two
    /// hover updates for the whole menu, not one per row crossed.
    @Test func aSweepOfEightMovesAcrossTheRowsHighlightsTwiceInOneFrame() throws {
        let harness = Harness()
        defer { harness.close() }
        var previous: Int?
        for step in 0..<8 {
            try harness.sweep(from: previous, to: step % 5)
            previous = step % 5
        }
        #expect(harness.highlights == ["i0"], "before the frame only the leading event highlighted")
        harness.frames.frame()
        #expect(harness.highlights == ["i0", "i\(7 % 5)"])
        #expect(harness.highlights.count <= 2, "more than 2 hover updates in one frame")
        #expect(harness.rows.hoverMoves.maxDeliveriesPerFrame <= 2)
        #expect(!harness.frames.coalescer.hasPending)
    }

    /// The pointer leaving the menu lands the pending move first; a frame after it highlights nothing.
    @Test func leavingTheMenuLandsThePendingMoveFirst() throws {
        let harness = Harness()
        defer { harness.close() }
        try harness.sweep(from: nil, to: 0)
        try harness.sweep(from: 0, to: 1)
        try harness.sweep(from: 1, to: 3)
        #expect(harness.frames.coalescer.hasPending)
        harness.rows.mouseExited(with: try PopupRowViewTests.crossing(.mouseExited, at: harness.center(3), in: harness.window))
        #expect(harness.highlights == ["i0", "i3"])
        #expect(!harness.frames.coalescer.hasPending, "the exit left a move for a later frame")
        harness.frames.frame()
        #expect(harness.highlights == ["i0", "i3"], "a move was delivered after the exit")
    }

    /// A press and its release pick the row under them; the pending move lands before the press.
    @Test func aPressLandsThePendingMoveThenTheReleasePicksItsRow() throws {
        let harness = Harness()
        defer { harness.close() }
        try harness.move(over: 1)
        try harness.move(over: 2)
        #expect(harness.frames.coalescer.hasPending)
        harness.rowViews[2].mouseDown(with: try PopupRowViewTests.mouse(.leftMouseDown, at: harness.center(2), in: harness.window))
        #expect(!harness.frames.coalescer.hasPending, "the press left a move for a later frame")
        #expect(harness.highlights == ["i1", "i2"])
        harness.rowViews[2].mouseUp(with: try PopupRowViewTests.mouse(.leftMouseUp, at: harness.center(2), in: harness.window))
        #expect(harness.picks == ["i2"])
    }

    /// With the feature off, every move and enter that changes the row highlights it at once.
    @Test func withoutFrameInputEveryMoveHighlights() throws {
        let harness = Harness(frameInput: false)
        defer { harness.close() }
        var previous: Int?
        for index in 0..<4 {
            try harness.sweep(from: previous, to: index)
            previous = index
        }
        #expect(harness.highlights == (0..<4).map { "i\($0)" })
        #expect(!harness.frames.coalescer.hasPending)
    }

    /// A row on its own (no popup consumer, the Extensions menu and Page Info today) takes the
    /// highlight back on a move after the keyboard moved it away.
    @Test func aRowWithoutAConsumerTakesTheHighlightBackOnAMove() throws {
        _ = NSApplication.shared
        let row = PopupRowView(leading: nil, title: "Row")
        var hovers = 0
        row.onHover = { hovers += 1 }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 40), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = row
        let move = try Self.mouse(.mouseMoved, at: CGPoint(x: 20, y: 10), in: window)
        row.mouseMoved(with: move)
        #expect(hovers == 1)
        row.isHighlighted = true
        row.mouseMoved(with: move)
        #expect(hovers == 1, "a highlighted row reports no move")
    }
}
