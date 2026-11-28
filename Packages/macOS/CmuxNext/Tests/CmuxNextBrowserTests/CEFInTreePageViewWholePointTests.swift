import AppKit
@testable import CmuxNextBrowser
import Testing

/// An in-tree page's container takes whole-point frames pinned to its host's top-left corner.
///
/// Chromium sizes a page in whole points: a `RenderWidgetHostViewCocoa` reports its bounds as an integer `gfx::Rect`
/// (truncating), and its frames are floored DIP sizes. Panes take half-point sizes in every frame of a divider drag, a
/// zoom or a window resize, so a half-point page view and Chromium's idea of it differed by up to a point: the viewport a
/// point off its pane. The fork now keeps the page's drawing layer on its view exactly (cef#48 one window,
/// `cmux_in_tree_display`, embedder case intree157-layerfit), which is why the app's layer fit is gone; the whole-point
/// container makes the view's size and Chromium's equal by construction.
@MainActor
@Suite struct CEFInTreePageViewWholePointTests {
    @Test func aHalfPointHostGivesAWholePointFrameAtItsTopLeft() {
        let host = NSRect(x: 0, y: 0, width: 266.5, height: 353.5)
        // An unflipped host: the top edge is maxY, so the frame starts half a point up.
        #expect(CEFInTreePageView.wholePointFrame(in: host, flipped: false) == NSRect(x: 0, y: 0.5, width: 266, height: 353))
        #expect(CEFInTreePageView.wholePointFrame(in: host, flipped: true) == NSRect(x: 0, y: 0, width: 266, height: 353))
        // Whole points stay as they are.
        let whole = NSRect(x: 0, y: 0, width: 600, height: 400)
        #expect(CEFInTreePageView.wholePointFrame(in: whole, flipped: false) == whole)
        #expect(CEFInTreePageView.wholePointFrame(in: .zero, flipped: false) == .zero)
    }

    /// Through 120 half-point host sizes, up and down, as a divider drag gives a pane: the container is always whole
    /// points, never overhangs the host, and its top edge is the host's.
    @Test func throughHalfPointResizesTheContainerStaysWholeAndPinnedTopLeft() {
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        let container = CEFInTreePageView(frame: CEFInTreePageView.wholePointFrame(in: host.bounds, flipped: host.isFlipped))
        host.addSubview(container)
        for i in 0..<120 {
            let size = NSSize(width: 300 + CGFloat((i * 37) % 200) * 0.5, height: 200 + CGFloat((i * 53) % 160) * 0.5)
            host.setFrameSize(size)
            let frame = container.frame
            #expect(frame.width == frame.width.rounded(.down) && frame.height == frame.height.rounded(.down),
                    "size \(i) \(size): container \(frame) is not whole points")
            #expect(frame.width <= size.width && frame.height <= size.height, "size \(i): \(frame) overhangs \(size)")
            #expect(size.width - frame.width < 1 && size.height - frame.height < 1, "size \(i): \(frame) leaves a point")
            #expect(frame.maxY == host.bounds.maxY && frame.minX == 0, "size \(i): \(frame) is not at the top-left of \(size)")
        }
    }
}
