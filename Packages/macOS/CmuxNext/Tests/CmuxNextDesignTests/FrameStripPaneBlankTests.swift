#if DEBUG || CMUX_BENCH_HOOKS
import CoreGraphics
@testable import CmuxNextDesign
import Testing

/// The frame strip's per-pane blank judge (``WindowFrame/PaneMeasure``): a split, close or side panel counts a blank frame
/// when any pane's content area shows one flat color that is neither its color before the key nor its settled one.
struct FrameStripPaneBlankTests {
    /// A 20x10 frame: the left half (x 0..<10) and right half (x 10..<20) each filled by `left` and `right`
    /// (a color, or nil for a stripe pattern that is not flat).
    static func frame(left: UInt8?, right: UInt8?) -> WindowFrame {
        var pixels: [UInt8] = []
        for y in 0..<10 {
            for x in 0..<20 {
                let value = (x < 10 ? left : right) ?? ((x + y) % 2 == 0 ? 0 : 200)
                pixels += [value, value, value, 255]
            }
        }
        return WindowFrame(milliseconds: 0, width: 20, height: 10, pixels: pixels)
    }

    static let leftPane = CGRect(x: 0, y: 0, width: 10, height: 10), rightPane = CGRect(x: 10, y: 0, width: 10, height: 10)

    @Test func aFlatColorNeitherBeforeNorFinalIsBlank() {
        #expect(WindowFrame.PaneMeasure.isBlank(flatness: 1, vsBefore: 1, vsFinal: 1, tolerance: 0.002))
        #expect(!WindowFrame.PaneMeasure.isBlank(flatness: 0.99, vsBefore: 1, vsFinal: 1, tolerance: 0.002))
        #expect(!WindowFrame.PaneMeasure.isBlank(flatness: 1, vsBefore: 0, vsFinal: 1, tolerance: 0.002))
        #expect(!WindowFrame.PaneMeasure.isBlank(flatness: 1, vsBefore: 1, vsFinal: 0.001, tolerance: 0.002))
    }

    @Test func anUnfocusedPaneGoingBlankCounts() async {
        // Both panes show content before and after; mid-transition the right (unfocused) pane flashes flat white.
        let before = Self.frame(left: nil, right: nil), last = Self.frame(left: nil, right: nil)
        let flash = Self.frame(left: nil, right: 255)
        let measures = await WindowFrame.measure([before, flash, last], before: before, last: last, content: Self.leftPane,
                                                 strip: nil, panes: [Self.leftPane, Self.rightPane])
        let blankCounts = measures.map { $0.panes.count(where: { $0.isBlank(tolerance: 0.002) }) }
        #expect(blankCounts == [0, 1, 0])
        // The focused pane's content area alone would not see it.
        #expect(measures[1].flatness < WindowFrame.PaneMeasure.flatShare)
    }

    @Test func aFlatPaneThatStaysFlatIsNotBlank() async {
        // An empty terminal: flat before, during and after.
        let before = Self.frame(left: nil, right: 30), last = Self.frame(left: nil, right: 30)
        let measures = await WindowFrame.measure([before, last], before: before, last: last, content: nil, strip: nil,
                                                 panes: [Self.rightPane])
        #expect(measures.allSatisfy { !$0.panes[0].isBlank(tolerance: 0.002) })
    }

    @Test func paneRectsDedupeAndCap() {
        let before = [CGRect(x: 0.2, y: 0, width: 9.7, height: 10), CGRect(x: 10, y: 0, width: 10, height: 10)]
        let final = [CGRect(x: 0, y: 0, width: 10, height: 10), CGRect(x: 0, y: 0, width: 20, height: 10), .zero]
        #expect(WindowFrame.paneRects(before: before, final: final) == [Self.leftPane, Self.rightPane, CGRect(x: 0, y: 0, width: 20, height: 10)])
        let many = (0..<40).map { CGRect(x: Double($0), y: 0, width: 1, height: 1) }
        #expect(WindowFrame.paneRects(before: many, final: [], cap: 16).count == 16)
    }
}
#endif
