import AppKit
@testable import CmuxNextBrowser
import CmuxNextWakeups
import CmuxNextWakeupsTestSupport
import Foundation
import Testing

/// Address bar suggestion rows hover once per frame (feature `pointerFrameHover`): the
/// card's rows share one consumer on p04-input-030's `FrameInputCoalescer`, so a frame interval's first
/// move reports its row in its own turn and the rest once at the frame, the row under the latest point
/// (Chromium's rAF-aligned moves, main_thread_event_queue.cc). Crossing into or out of a row coalesces
/// like a move (Blink derives boundary events from those moves, boundary_event_dispatcher.cc); leaving
/// the card and a press land the pending move first. The omnibar state machine still decides the highlight.
@MainActor @Suite(.serialized) struct SuggestionRowTests {
    @MainActor final class Harness {
        let bar = AddressBarView(mainWork: MainWorkScheduler(budget: MainFrameBudget()))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        let frames = FrameInputTestRig()
        /// Every row the card reported under the pointer (nil: it left the rows), in order.
        var hovers: [Int?] = []

        init(frameInput: Bool = true) throws {
            _ = NSApplication.shared
            window.isReleasedWhenClosed = false
            bar.frame = NSRect(x: 10, y: 340, width: 600, height: 34)
            let pane = try #require(window.contentView)
            pane.addSubview(bar)
            if frameInput { bar.hoverFrameInput = frames.coalescers }
            let url = try #require(URL(string: "https://example.com/"))
            let rows = (0..<5).map { BrowserSuggestion(kind: .search, title: "query \($0)", detail: "", url: url, score: 1) }
            bar.panel.show(rows, highlighted: 0, at: bar, pane: pane, in: window)
            bar.panel.onHover = { [unowned self] row, _ in hovers.append(row) }
        }

        var rows: [SuggestionRowView] { bar.panel.rowViews }

        func center(_ index: Int) -> CGPoint {
            let row = rows[index]
            return row.convert(CGPoint(x: row.bounds.midX, y: row.bounds.midY), to: nil)
        }

        func event(_ type: NSEvent.EventType, row index: Int) throws -> NSEvent {
            try event(type, at: center(index))
        }

        func event(_ type: NSEvent.EventType, at point: CGPoint) throws -> NSEvent {
            let cardWindow = try #require(rows.first?.window, "the card is not on a window")
            switch type {
            case .mouseEntered, .mouseExited:
                return try #require(NSEvent.enterExitEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                                                           windowNumber: cardWindow.windowNumber, context: nil, eventNumber: 0,
                                                           trackingNumber: 0, userData: nil))
            default:
                return try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                                                       timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: cardWindow.windowNumber,
                                                       context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1))
            }
        }

        func move(over index: Int) throws { rows[index].mouseMoved(with: try event(.mouseMoved, row: index)) }

        /// One move from row `from` (nil: from outside the card) onto row `to`, as AppKit delivers it: the
        /// old row's exit, the new row's enter, then the move, every one at the new point.
        func sweep(from: Int?, to index: Int) throws {
            if let from, from != index { rows[from].mouseExited(with: try event(.mouseExited, row: index)) }
            if from != index { rows[index].mouseEntered(with: try event(.mouseEntered, row: index)) }
            try move(over: index)
        }

        /// A point on the card's window outside every row (below the card).
        var outside: CGPoint {
            let card = bar.panel.cardView
            return card.convert(CGPoint(x: card.bounds.midX, y: card.bounds.minY - 20), to: nil)
        }

        func close() {
            bar.panel.dismiss()
            frames.close()
            window.close()
        }
    }

    /// A lone move after an idle frame reports its row in the same turn.
    @Test func aSingleMoveAfterAnIdleFrameReportsInTheSameTurn() throws {
        let harness = try Harness()
        defer { harness.close() }
        try #require(harness.rows.count == 5)
        try harness.move(over: 2)
        #expect(harness.hovers == [2])
        #expect(!harness.frames.coalescer.hasPending)
    }

    /// A fast sweep in one frame: eight moves over the rows, with every row's exit and enter in AppKit's
    /// order. The leading event reports at once and the row under the last move at the frame: two
    /// reports for the whole card, not one (or two) per row crossed.
    @Test func aSweepOfEightMovesAcrossTheRowsReportsTwiceInOneFrame() throws {
        let harness = try Harness()
        defer { harness.close() }
        var previous: Int?
        for step in 0..<8 {
            try harness.sweep(from: previous, to: step % 5)
            previous = step % 5
        }
        #expect(harness.hovers == [0], "before the frame only the leading event reported")
        harness.frames.frame()
        #expect(harness.hovers == [0, 7 % 5])
        #expect(harness.hovers.count <= 2, "more than 2 hover reports in one frame")
        #expect(harness.bar.panel.hoverMoves.maxDeliveriesPerFrame <= 2)
        #expect(!harness.frames.coalescer.hasPending)
    }

    /// Leaving the card lands the pending move first, at the pointer's last point (off the rows: the
    /// pointer left them); a frame after it reports nothing more.
    @Test func leavingTheCardLandsThePendingMoveFirst() throws {
        let harness = try Harness()
        defer { harness.close() }
        try harness.sweep(from: nil, to: 1)
        try harness.sweep(from: 1, to: 3)
        let outside = harness.outside
        harness.rows[3].mouseExited(with: try harness.event(.mouseExited, at: outside))
        #expect(harness.hovers == [1], "a row's exit reported before the frame")
        harness.bar.panel.cardView.mouseExited(with: try harness.event(.mouseExited, at: outside))
        #expect(harness.hovers == [1, nil])
        #expect(!harness.frames.coalescer.hasPending, "the exit left a move for a later frame")
        harness.frames.frame()
        #expect(harness.hovers == [1, nil], "a move was delivered after the exit")
    }

    /// A press lands the pending move before the click; the click picks the row under it.
    @Test func aPressLandsThePendingMoveBeforeTheClick() throws {
        let harness = try Harness()
        defer { harness.close() }
        var picked: [Int] = []
        harness.bar.panel.onPick = { row, _ in picked.append(row) }
        try harness.move(over: 0)
        try harness.move(over: 4)
        #expect(harness.frames.coalescer.hasPending)
        harness.rows[4].mouseDown(with: try harness.event(.leftMouseDown, row: 4))
        #expect(!harness.frames.coalescer.hasPending, "the press left a move for a later frame")
        #expect(harness.hovers == [0, 4])
        harness.rows[4].mouseUp(with: try harness.event(.leftMouseUp, row: 4))
        #expect(picked == [4])
    }

    /// With the feature off, every move reports its row at once.
    @Test func withoutFrameInputEveryMoveReports() throws {
        let harness = try Harness(frameInput: false)
        defer { harness.close() }
        for index in 0..<4 { try harness.move(over: index) }
        #expect(harness.hovers == [0, 1, 2, 3])
        #expect(!harness.frames.coalescer.hasPending)
    }

    /// With the feature off, a row's exit and enter report the row under the pointer at once, as a move
    /// does.
    @Test func withoutFrameInputACrossingReportsTheRowUnderThePointer() throws {
        let harness = try Harness(frameInput: false)
        defer { harness.close() }
        try harness.sweep(from: nil, to: 0)
        try harness.sweep(from: 0, to: 2)
        #expect(harness.hovers == [0, 0, 2, 2, 2])
        harness.rows[2].mouseExited(with: try harness.event(.mouseExited, at: harness.outside))
        #expect(harness.hovers.last == .some(nil), "the exit off the card did not report leaving the rows")
    }
}
