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
        #expect(WindowFrame.PaneMeasure.isBlank(flatness: 1, vsBefore: 1, vsFinal: 1, settledInk: 0, tolerance: 0.002))
        #expect(!WindowFrame.PaneMeasure.isBlank(flatness: 0.99, vsBefore: 1, vsFinal: 1, settledInk: 0.01, tolerance: 0.002))
        #expect(!WindowFrame.PaneMeasure.isBlank(flatness: 1, vsBefore: 0, vsFinal: 1, settledInk: 0, tolerance: 0.002))
        #expect(!WindowFrame.PaneMeasure.isBlank(flatness: 1, vsBefore: 1, vsFinal: 0.001, settledInk: 0, tolerance: 0.002))
        // Flat, unlike both, but it kept its ink (a prompt drawn where neither frame has it): drawn, not blank.
        #expect(!WindowFrame.PaneMeasure.isBlank(flatness: 0.997, vsBefore: 0.01, vsFinal: 0.01, settledInk: 0.003, tolerance: 0.002))
        #expect(WindowFrame.PaneMeasure.isBlank(flatness: 0.9995, vsBefore: 0.01, vsFinal: 0.01, settledInk: 0.003, tolerance: 0.002))
        // A flash of another background color keeps its prompt yet differs almost everywhere: blank (#39072 review F1).
        #expect(WindowFrame.PaneMeasure.isBlank(flatness: 0.9988, vsBefore: 1, vsFinal: 1, settledInk: 0.0012, tolerance: 0.002))
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

    /// A 200x100 light frame with a dark 6x2 "prompt" at (`x`, `y`) in the pane on the right (x 100..<200), or none.
    static func terminal(promptAt origin: (x: Int, y: Int)?) -> WindowFrame {
        var pixels: [UInt8] = []
        for y in 0..<100 {
            for x in 0..<200 {
                let ink = origin.map { x >= $0.x && x < $0.x + 6 && y >= $0.y && y < $0.y + 2 } ?? false
                let value: UInt8 = ink ? 20 : 250
                pixels += [value, value, value, 255]
            }
        }
        return WindowFrame(milliseconds: 0, width: 200, height: 100, pixels: pixels)
    }

    @Test func aDrawnEmptyTerminalMovingIsNotBlank() async {
        // An empty terminal's prompt (0.12% of the pane: flat) moves with its pane: mid-motion it sits where neither
        // the frame before the key nor the last one has it, yet it is drawn. Without its prompt, the pane is blank.
        let pane = CGRect(x: 100, y: 0, width: 100, height: 100)
        let before = Self.terminal(promptAt: (110, 10)), last = Self.terminal(promptAt: (130, 50))
        let moving = Self.terminal(promptAt: (120, 30)), empty = Self.terminal(promptAt: nil)
        let measures = await WindowFrame.measure([before, moving, empty, last], before: before, last: last, content: pane,
                                                 strip: nil, panes: [pane])
        #expect(measures[1].flatness > WindowFrame.PaneMeasure.flatShare)
        #expect(measures.map { $0.panes[0].isBlank(tolerance: 0.0005) } == [false, false, true, false])
        #expect(measures.map {
            WindowFrame.PaneMeasure.isBlank(flatness: $0.flatness, vsBefore: $0.insideBefore, vsFinal: $0.insideFinal,
                                            settledInk: $0.settledInk, tolerance: 0.0005)
        } == [false, false, true, false])
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
