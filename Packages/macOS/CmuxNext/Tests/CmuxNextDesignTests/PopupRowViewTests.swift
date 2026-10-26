import AppKit
@testable import CmuxNextDesign
import CmuxNextWakeupsTestSupport
import Testing

/// Native popup rows hover once per frame (feature `pointerFrameHover`, p04-input-037): a page menu's
/// rows (``WebPopupRows``) share the menu's one consumer on p04-input-030's `FrameInputCoalescer`, so a
/// frame interval's first move hovers in its own turn and the rest once at the frame, the row under the
/// latest point (Chromium's rAF-aligned moves, main_thread_event_queue.cc). Enter, exit and a press land
/// the pending move first. A row with no consumer acts on every move.
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

    /// Eight moves over the rows in one frame: the leading row at once, the row under the last move at
    /// the frame. Two hover updates for the whole menu, not one per row.
    @Test func eightMovesInOneFrameHighlightTheLeadingAndTheLatestRow() throws {
        let harness = Harness()
        defer { harness.close() }
        for step in 0..<8 { try harness.move(over: step % 5) }
        #expect(harness.highlights == ["i0"], "before the frame only the leading move highlighted")
        harness.frames.frame()
        #expect(harness.highlights == ["i0", "i\(7 % 5)"])
        #expect(harness.rows.hoverMoves.maxDeliveriesPerFrame == 2)
        #expect(!harness.frames.coalescer.hasPending)
    }

    /// Entering a row lands the pending move first, then highlights the entered row; a frame after it
    /// moves nothing back.
    @Test func anEnterLandsThePendingMoveFirst() throws {
        let harness = Harness()
        defer { harness.close() }
        try harness.move(over: 0)
        try harness.move(over: 1)
        harness.rowViews[3].mouseEntered(with: try PopupRowViewTests.crossing(.mouseEntered, at: harness.center(3), in: harness.window))
        #expect(harness.highlights == ["i0", "i1", "i3"])
        harness.frames.frame()
        #expect(harness.highlights == ["i0", "i1", "i3"], "a move was delivered after the enter")
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

    /// With the feature off, every move that changes the row highlights it at once.
    @Test func withoutFrameInputEveryMoveHighlights() throws {
        let harness = Harness(frameInput: false)
        defer { harness.close() }
        for index in 0..<4 { try harness.move(over: index) }
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
