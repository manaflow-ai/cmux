import CmuxNextBridge
import CoreGraphics
@testable import CmuxNextLayout
import Testing

/// Review of #32550 (FIX FIRST at 77abc43df41, comment 6587348634): a row's lowest useful permille must come from the
/// pixel grid at the screen's scale. Rounded to the nearest permille it was up to half a permille low (a dead Up press,
/// #32550's red); rounded up from the exact placement it can show one device pixel above the minimum (Up refused while
/// one more pixel could move), and at 1x dead presses remained. At 1x and 2x, from any stored height just above the
/// minimum: every Up press that changes the model moves the edge, and the presses end with the row at its minimum.
struct KeyboardResizeRowsPixelFloorTests {
    static let viewport = CGSize(width: 1153, height: 857)

    static func layout(_ upper: Int) -> ScreenLayout {
        .columns([LayoutColumn(id: "c0", width: 1, root: .split("compat", axis: .vertical, ratio: 0.5, a: .leaf("p1"), b: .leaf("p2")),
                               rows: [LayoutRow(id: "r0", height: upper, root: .leaf("p1")),
                                      LayoutRow(id: "r1", height: 1000 - upper, root: .leaf("p2"))])])
    }

    @Test(arguments: [CGFloat(1), CGFloat(2)])
    func upPressesNeverDieAndEndAtTheRowMinimum(scale: CGFloat) {
        var dead: [String] = [], short: [String] = []
        for quarter in stride(from: 0, through: 1344, by: 3) {
            var style = LayoutStyle()
            style.rowsEnabled = true
            style.minimumPaneContentSize = CGSize(width: 200, height: 64 + CGFloat(quarter) / 4)
            let minimum = SplitGeometry.minimumSize(of: .leaf("p1"), style: style).height
            let stack0 = ScreenGeometry.compute(Self.layout(500), viewport: Self.viewport, style: style, scale: scale).rowStacks["c0"]!
            let near = RowStackGeometry.permille(forPixelHeight: minimum, columnHeight: stack0.frame.height, gap: stack0.gap)
            for start in (near - 1)...(near + 3) where start >= LayoutRow.heightRange.lowerBound && start < 900 {
                var layout = Self.layout(start)
                for _ in 0..<6 {
                    let geometry = ScreenGeometry.compute(layout, viewport: Self.viewport, style: style, scale: scale)
                    let before = geometry.rowStacks["c0"]!.rows[0].frame.height
                    guard case .rowHeights(let column, let heights)? = PaneResize.change(
                        for: "p1", direction: .up, in: layout, shown: ShownResizeRange(geometry: geometry, style: style, scale: scale)) else { break }
                    layout = layout.settingRowHeights(heights, for: column)
                    let after = ScreenGeometry.compute(layout, viewport: Self.viewport, style: style, scale: scale).rowStacks["c0"]!.rows[0].frame.height
                    if after >= before { dead.append("min \(minimum) start \(start): \(heights.map(\.height)) kept \(before)") }
                }
                let shown = ScreenGeometry.compute(layout, viewport: Self.viewport, style: style, scale: scale).rowStacks["c0"]!.rows[0].frame.height
                if shown != SplitGeometry.ceilToPixel(minimum, scale: scale) { short.append("min \(minimum) start \(start): stops at \(shown)") }
            }
        }
        #expect(dead.isEmpty, "\(dead.count) dead Up presses at \(scale)x, first: \(dead.prefix(3))")
        #expect(short.isEmpty, "\(short.count) rows stop above their minimum at \(scale)x, first: \(short.prefix(3))")
    }
}
