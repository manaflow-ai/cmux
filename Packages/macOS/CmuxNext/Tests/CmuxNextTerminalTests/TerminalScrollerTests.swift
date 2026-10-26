import AppKit
import CmuxNextDesign
@testable import CmuxNextTerminal
import CmuxNextWakeups
import CmuxNextWakeupsTestSupport
import Testing

/// The terminal's scroller hears its own clip move from the clip (p03-rendering-039), not from a
/// NotificationCenter observer of the clip: a scroller drag reports the row it shows, and the
/// scroller's own placement for Ghostty's scrollbar reports nothing back. Its knob is placed at most
/// once per frame interval (p04-input-051): the interval's first change at once, the latest of the
/// rest at the frame.
@MainActor
struct TerminalScrollerTests {
    private let frames = ScrollerFrameRig()

    private func scroller() -> TerminalScroller {
        let scheduler = frames.scheduler
        let scroller = TerminalScroller { _ in scheduler }
        scroller.frame = NSRect(x: 0, y: 0, width: 12, height: 100)
        scroller.tile()
        return scroller
    }

    private static func bar(_ offset: UInt64) -> TerminalScrollbar {
        TerminalScrollbar(totalRows: 100, offsetRows: offset, visibleRows: 10)
    }

    @Test func theClipIsTheSharedGeometryClip() {
        let scroller = scroller()
        #expect(scroller.contentView is ScrollGeometryClipView)
        #expect(ScrollGeometryClipView.install(in: scroller) === scroller.contentView, "a later client keeps the clip")
    }

    @Test func aClipMoveReportsTheRowAtTheTop() {
        let scroller = scroller()
        var rows: [UInt64] = []
        scroller.onScrollToRow = { rows.append($0) }
        scroller.update(Self.bar(90))
        #expect(rows.isEmpty, "placing the knob for Ghostty's scrollbar is not a user move")
        // Ten points a row: a 100 pt viewport shows 10 rows.
        scroller.contentView.scroll(to: NSPoint(x: 0, y: 400))
        #expect(rows == [40])
    }

    @Test func anUpdateThatMovesTheViewportReportsNothing() {
        let scroller = scroller()
        var rows: [UInt64] = []
        scroller.onScrollToRow = { rows.append($0) }
        scroller.update(Self.bar(90))
        scroller.update(Self.bar(20))
        frames.frame()
        #expect(scroller.contentView.bounds.origin.y == 200)
        #expect(rows.isEmpty)
    }

    @Test func aMoveToTheRowAlreadyShownReportsNothing() {
        let scroller = scroller()
        var rows: [UInt64] = []
        scroller.onScrollToRow = { rows.append($0) }
        scroller.update(Self.bar(30))
        scroller.contentView.scroll(to: NSPoint(x: 0, y: 301)) // rounds to row 30
        #expect(rows.isEmpty)
    }

    /// Five scrollbar actions in one frame interval: the first places the knob at once, the rest wait
    /// and the frame places the latest, once. A frame with nothing new ends the interval.
    @Test func updatesInOneFrameIntervalPlaceTheKnobOnce() {
        let scroller = scroller()
        for offset: UInt64 in [90, 80, 70, 60, 50] { scroller.update(Self.bar(offset)) }
        #expect(scroller.knobPlacements == 1, "\(scroller.knobPlacements) placements in one frame interval")
        #expect(scroller.shown == Self.bar(90), "the interval's first change waited for the frame")
        #expect(scroller.contentView.bounds.origin.y == 900)
        frames.frame()
        #expect(scroller.knobPlacements == 2)
        #expect(scroller.shown == Self.bar(50), "the frame did not place the latest scrollbar")
        #expect(scroller.contentView.bounds.origin.y == 500)
        frames.frame()
        #expect(scroller.knobPlacements == 2, "a frame with nothing new placed the knob")
        #expect(frames.scheduler.activeClients.isEmpty, "the scroller kept frames after its interval ended")
        scroller.update(Self.bar(40))
        #expect(scroller.knobPlacements == 3 && scroller.shown == Self.bar(40), "a new interval's first change waited")
    }

    /// A clip resize inside an interval joins the frame's one placement; a layout at the placed clip
    /// size (the scroller's own document change) places nothing.
    @Test func aClipResizeInAnIntervalWaitsForTheFrame() {
        let scroller = scroller()
        scroller.update(Self.bar(0))
        #expect(scroller.knobPlacements == 1)
        scroller.layout()
        #expect(scroller.knobPlacements == 1, "a layout at the placed clip size placed the knob")
        scroller.frame = NSRect(x: 0, y: 0, width: 12, height: 200)
        scroller.tile()
        scroller.layout()
        #expect(scroller.knobPlacements == 1, "the resize placed the knob inside the interval")
        frames.frame()
        #expect(scroller.knobPlacements == 2)
        // Twenty points a row now: the document stands for 100 rows.
        #expect(scroller.documentView?.frame.height == 2000)
    }

    /// A knob drag reports each clip move at once and in order while Ghostty's newer scrollbar waits
    /// for the frame; a move back to the shown row still reports, and one to Ghostty's row does not.
    @Test func aKnobDragReportsEveryMoveWhileABarWaits() {
        let scroller = scroller()
        var rows: [UInt64] = []
        scroller.onScrollToRow = { rows.append($0) }
        scroller.update(Self.bar(90))
        scroller.update(Self.bar(80)) // waits for the frame
        #expect(scroller.shown == Self.bar(90))
        for y: CGFloat in [400, 900, 800, 300] { scroller.contentView.scroll(to: NSPoint(x: 0, y: y)) }
        #expect(rows == [40, 90, 30])
    }
}

/// A frame scheduler on a fake link whose frames come only when a test calls ``frame()``.
@MainActor
private final class ScrollerFrameRig {
    let scheduler = FrameScheduler.testing(clock: ManualClock(), ledger: WakeupLedger(), mediaTime: { 1000 }) { _ in
        ScrollerTestLink()
    }
    private var count = 0

    /// One 120 Hz link frame.
    func frame() {
        count += 1
        scheduler.frameDidFire(timestamp: 1000 + Double(count) / 120, refreshInterval: 1.0 / 120)
    }
}

@MainActor
private final class ScrollerTestLink: FrameLink {
    var isPaused = false
    func invalidate() {}
}
