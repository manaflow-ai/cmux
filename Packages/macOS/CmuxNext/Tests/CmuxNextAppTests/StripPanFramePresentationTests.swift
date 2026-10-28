import AppKit
@testable import CmuxNextLayout
import CoreGraphics
import Testing

/// A strip pan shows at most once per display frame (PL-scroll: 6-10 % missed frames at 120 Hz in a
/// light session, Command and plain scroll alike). The first pan event of a frame moves the panes in
/// its own turn; a later event of the same frame waits, and the frame's tick shows them all in one
/// presentation. A frame tick while the finger is down is not the pan's landing: the layout stays in
/// motion, so what waits for the landing (page windows, divider catcher panels) does not sync on it.
/// The test is the display clock (`driver.isManual`): `advanceFrame` is one display frame.
@MainActor
struct StripPanFramePresentationTests {
    /// The presented x of `pane`'s host (the frame the window shows), in the screen's coordinates.
    private static func shownX(_ w: LayoutScrollModifierTests.Window, _ pane: PaneID) throws -> CGFloat {
        try #require(w.root.context.hosts[pane]).frame.minX
    }

    @Test func aSecondPanEventInOneFrameShowsAtTheFramesTick() throws {
        let w = LayoutScrollModifierTests.Window(modifier: .command)
        let point = try w.center("p2")
        let rest = try Self.shownX(w, "p2")
        #expect(w.scroll(at: point, dx: -20, phase: .began, command: true), "the layout takes the Command gesture")
        let first = try Self.shownX(w, "p2")
        #expect(first < rest - 1, "the frame's first pan event moves the panes at once: \(rest) -> \(first)")
        #expect(w.scroll(at: point, dx: -20, phase: .changed, command: true))
        #expect(try Self.shownX(w, "p2") == first, "a second event in the same frame waits for the frame's tick")
        _ = w.root.advanceFrame(1.0 / 120)
        let ticked = try Self.shownX(w, "p2")
        #expect(ticked < first - 1, "the frame tick shows the waiting event: \(first) -> \(ticked)")
        #expect(w.scroll(at: point, dx: -20, phase: .changed, command: true))
        #expect(try Self.shownX(w, "p2") < ticked - 1, "the next frame's first event moves the panes at once")
        w.scroll(at: point, phase: .ended, command: true)
        w.settle()
    }

    @Test func aFrameTickWithTheFingerDownKeepsTheLayoutInMotion() throws {
        let w = LayoutScrollModifierTests.Window(modifier: .command)
        let point = try w.center("p2")
        #expect(w.scroll(at: point, dx: -20, phase: .began, command: true))
        #expect(w.root.isLayoutInMotion, "the pan's first move starts the layout motion")
        for _ in 0..<3 {
            _ = w.root.advanceFrame(1.0 / 120)
            #expect(w.root.isLayoutInMotion, "a frame tick during the pan is not its landing")
            #expect(w.scroll(at: point, dx: -20, phase: .changed, command: true))
        }
        w.scroll(at: point, phase: .ended, command: true)
        w.settle()
        #expect(!w.root.isLayoutInMotion, "the pan landed")
    }
}
