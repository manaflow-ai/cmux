import AppKit
import CmuxNextBridge
@testable import CmuxNextLayout
import Testing

/// Scratch measurement for the review of #34123 (not part of the PR): the main-thread cost of one key trade's
/// `PaneResize.change` on large strips (it places the candidate with `ScreenGeometry.compute` up to twice), next to one
/// `ScreenGeometry.compute` of the same screen (the press's own sync does at least one).
struct KeyTradeCostMeasurement {
    static func strip(_ count: Int) -> ScreenLayout {
        .columns((0..<count).map { index in
            let a = PaneID("p\(index)a"), b = PaneID("p\(index)b"), c = PaneID("p\(index)c"), d = PaneID("p\(index)d")
            // Vertical splits only: a Left/Right press on any pane is a trade between columns.
            let top: SplitNode = .split(SplitID("t\(index)"), axis: .vertical, ratio: 0.5, a: .leaf(a), b: .leaf(b))
            let bottom: SplitNode = .split(SplitID("b\(index)"), axis: .vertical, ratio: 0.5, a: .leaf(c), b: .leaf(d))
            return LayoutColumn(id: ColumnID("c\(index)"), width: 0.5, root: .split(SplitID("v\(index)"), axis: .vertical, ratio: 0.5, a: top, b: bottom))
        })
    }

    static func percentiles(_ samples: [Duration]) -> String {
        let ms = samples.map { Double($0.components.attoseconds) / 1e15 + Double($0.components.seconds) * 1000 }.sorted()
        func at(_ q: Double) -> Double { ms[min(ms.count - 1, Int(Double(ms.count) * q))] }
        return String(format: "p50 %.3f ms, p95 %.3f ms, p99 %.3f ms, max %.3f ms", at(0.5), at(0.95), at(0.99), ms.last ?? 0)
    }

    @Test(arguments: [8, 32, 64])
    func measure(columns: Int) {
        var style = LayoutStyle()
        style.columnGap = 0
        let viewport = CGSize(width: 2560, height: 1440)
        let layout = Self.strip(columns)
        let geometry = ScreenGeometry.compute(layout, viewport: viewport, style: style, scale: 2)
        let shown = ShownResizeRange(geometry: geometry, style: style, scale: 2, stripOffset: 0)
        let clock = ContinuousClock()
        var change: [Duration] = [], compute: [Duration] = []
        for _ in 0..<300 {
            change.append(clock.measure { _ = PaneResize.change(for: "p0a", direction: .right, in: layout, shown: shown) })
            compute.append(clock.measure { _ = ScreenGeometry.compute(layout, viewport: viewport, style: style, scale: 2) })
        }
        guard case .columnTrade? = PaneResize.change(for: "p0a", direction: .right, in: layout, shown: shown) else {
            Issue.record("the press is no trade")
            return
        }
        print("KEY-TRADE-COST columns=\(columns) panes=\(columns * 4) change: \(Self.percentiles(change)); compute: \(Self.percentiles(compute))")
    }
}
