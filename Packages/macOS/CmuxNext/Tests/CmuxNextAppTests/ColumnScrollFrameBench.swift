import CmuxNextDesign
import CmuxNextLayout
import CoreGraphics
import Foundation
import Testing

/// The main-thread cost of column scrolling per display frame at 120 Hz: the scroll reducer's
/// event (a sync, a trackpad delta, a gesture end, a wheel notch) plus the spring step that frame,
/// in nanoseconds per frame (p50, p95, p99, max), for a columns strip, a column's overflowing rows
/// and a scroll area, driven the way ScreenContentView drives them. A measurement, not a gate: the
/// B1 A/B (Swift rules against the Rust reducer, cmux_scroll_*) runs it alone on an exclusive host,
/// once with each arm's Scroll sources. Source-compatible with both arms.
///
/// `copyOut` is the pattern the row and area callers used before B1 step B (copy the scroll
/// value out of its dictionary, reduce, write it back), measured beside the in-place pattern they
/// use now, so the A/B shows what the copy costs with the Rust handle (copy on write).
///
/// ```
/// CMUX_COLUMN_SCROLL_BENCH=1 swift test -c release --filter ColumnScrollFrameBench
/// ```
@MainActor
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["CMUX_COLUMN_SCROLL_BENCH"] == "1"))
struct ColumnScrollFrameBench {
    private static let sessions = 400
    private static let dt = 1.0 / 120.0
    private static let spring = SpringParameters(response: 0.2, dampingFraction: 0.9)
    /// One display frame at 120 Hz.
    private static let budget: UInt64 = 8_333_333

    /// Eight 800 pt columns of two panes on a 1200 pt strip.
    private static func strip() -> ColumnStrip {
        let columns = (0..<8).map { index -> ColumnStrip.Column in
            let x = 16 + CGFloat(index) * 816
            let top = CGRect(x: x, y: 0, width: 800, height: 392), bottom = CGRect(x: x, y: 408, width: 800, height: 392)
            let panes = [PaneID("p\(index)a"), PaneID("p\(index)b")]
            return ColumnStrip.Column(id: ColumnID("c\(index)"), frame: CGRect(x: x, y: 0, width: 800, height: 800), panes: panes,
                                      paneFrames: [panes[0]: top, panes[1]: bottom])
        }
        return ColumnStrip(columns: columns, viewportWidth: 1200, contentWidth: 8 * 816 + 16, gap: 16)
    }

    /// A column of six 500-permille rows (they overflow it), and a split chain of four panes that
    /// needs more width than its 700 pt screen (a scroll area).
    private static func geometry() -> (rows: ScreenGeometry, column: LayoutColumn, area: ScreenGeometry) {
        let rows = (1...6).map { LayoutRow(id: RowID("r\($0)"), height: 500, root: .leaf(PaneID("row\($0)"))) }
        func chain(_ rest: ArraySlice<LayoutRow>) -> SplitNode {
            guard rest.count > 1, let first = rest.first else { return rest.first?.root ?? .leaf("row1") }
            return .split(SplitID("v\(first.id.rawValue)"), axis: .vertical, ratio: 1 / Double(rest.count), a: first.root,
                          b: chain(rest.dropFirst()))
        }
        let column = LayoutColumn(id: "rows", width: 1, root: chain(rows[...]), rows: rows)
        let rowGeometry = ScreenGeometry.compute(.columns([column]), viewport: CGSize(width: 1200, height: 800), style: LayoutStyle())
        var areaStyle = LayoutStyle()
        areaStyle.minimumPaneContentSize = CGSize(width: 300, height: 64)
        areaStyle.scrollAreasEnabled = true
        let tree: SplitNode = .split("a1", axis: .horizontal, ratio: 0.25, a: .leaf("q1"),
                                     b: .split("a2", axis: .horizontal, ratio: 1.0 / 3, a: .leaf("q2"),
                                               b: .split("a3", axis: .horizontal, ratio: 0.5, a: .leaf("q3"), b: .leaf("q4"))))
        let areaGeometry = ScreenGeometry.compute(.splits(tree), viewport: CGSize(width: 700, height: 800), style: areaStyle)
        return (rowGeometry, column, areaGeometry)
    }

    /// Times one frame: `event` (nil: a frame with no input) and the spring step.
    private static func frame(_ samples: inout [UInt64], _ body: () -> Void) {
        let start = DispatchTime.now().uptimeNanoseconds
        body()
        samples.append(DispatchTime.now().uptimeNanoseconds - start)
    }

    /// One scrolling session on `state`: a focus sync, a 60-frame trackpad drag, the release and
    /// its spring frames, a wheel notch and its frames, and a keyboard focus sync and its frames.
    private static func session(_ samples: inout [UInt64], sync: (inout [UInt64], PaneID) -> Void,
                                reduce: (ColumnScrollEvent) -> Void, step: () -> Bool, focus: [PaneID], round: Int) {
        sync(&samples, focus[round % focus.count])
        frame(&samples) { reduce(.gestureBegan) }
        var time = 0.0
        for index in 0..<60 {
            time += dt
            frame(&samples) { reduce(.gestureChanged(deltaX: index < 30 ? -14 : 9, time: time)) }
        }
        frame(&samples) { reduce(.gestureEnded(time: time + dt, animated: true)) }
        var moving = true
        for _ in 0..<240 where moving { frame(&samples) { moving = step() } }
        frame(&samples) { reduce(.wheel(direction: round.isMultiple(of: 2) ? 1 : -1, animated: true)) }
        moving = true
        for _ in 0..<240 where moving { frame(&samples) { moving = step() } }
        sync(&samples, focus[(round + 3) % focus.count])
        moving = true
        for _ in 0..<240 where moving { frame(&samples) { moving = step() } }
    }

    private static func report(_ label: String, _ samples: [UInt64]) {
        let sorted = samples.sorted()
        func quantile(_ q: Double) -> UInt64 { sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(Double(sorted.count) * q))] }
        let over = sorted.filter { $0 > budget }.count
        print("column-scroll bench \(label): \(sorted.count) frames: p50 \(quantile(0.5)) ns, p95 \(quantile(0.95)) ns, "
              + "p99 \(quantile(0.99)) ns, max \(sorted.last ?? 0) ns, over 8.33 ms \(over)")
    }

    @Test func nanosecondsPerFrame() {
        print("column-scroll bench: macOS \(ProcessInfo.processInfo.operatingSystemVersionString), \(Self.sessions) sessions per case")
        let strip = Self.strip()
        let focus = strip.columns.flatMap(\.panes)
        let (rowGeometry, rowColumn, areaGeometry) = Self.geometry()
        guard let stack = rowGeometry.rowStacks[ColumnID("rows")], let area = areaGeometry.scrollAreas.values.first else {
            Issue.record("the bench layout has no row stack or scroll area")
            return
        }
        let rowFocus = rowColumn.rows.map { $0.root.panes.first ?? "row1" }
        let areaFocus = area.panes

        // Columns: one state, as ScreenContentView.scrollState.
        var columns: [UInt64] = []
        var state = ColumnScrollState()
        for round in 0..<Self.sessions {
            Self.session(&columns, sync: { samples, pane in
                Self.frame(&samples) { state.reduce(.sync(strip, focused: pane, source: .keyboard, animated: true)) }
            }, reduce: { state.reduce($0) }, step: { state.spring.advance(Self.dt, parameters: Self.spring, epsilon: 0.25) },
            focus: focus, round: round)
        }
        Self.report("columns", columns)

        // Rows and an area, in place in a dictionary (ScreenContentView+Rows/+ScrollAreas today).
        for copyOut in [false, true] {
            var rows: [UInt64] = []
            var rowScrolls: [ColumnID: RowScroll] = [:]
            let id = ColumnID("rows")
            for round in 0..<Self.sessions {
                Self.session(&rows, sync: { samples, pane in
                    Self.frame(&samples) {
                        if copyOut {
                            var scroll = rowScrolls[id] ?? RowScroll()
                            let rowStrip = scroll.strip(rows: stack, column: rowColumn, panes: rowGeometry.panes)
                            scroll.state.reduce(.sync(rowStrip, focused: pane, source: .keyboard, animated: true))
                            rowScrolls[id] = scroll
                        } else {
                            // As ScreenContentView+Rows: no local copy holds the value while it reduces.
                            if rowScrolls[id] == nil { rowScrolls[id] = RowScroll() }
                            guard let rowStrip = rowScrolls[id]?.strip(rows: stack, column: rowColumn, panes: rowGeometry.panes) else { return }
                            rowScrolls[id]?.state.reduce(.sync(rowStrip, focused: pane, source: .keyboard, animated: true))
                        }
                    }
                }, reduce: { event in
                    if copyOut, var scroll = rowScrolls[id] {
                        scroll.state.reduce(event)
                        rowScrolls[id] = scroll
                    } else {
                        rowScrolls[id]?.state.reduce(event)
                    }
                }, step: { rowScrolls[id]?.state.spring.advance(Self.dt, parameters: Self.spring, epsilon: 0.25) ?? false },
                focus: rowFocus, round: round)
            }
            Self.report(copyOut ? "rows (copy out)" : "rows (in place)", rows)

            var areas: [UInt64] = []
            var areaScrolls: [SplitID: ScrollAreaScroll] = [:]
            for round in 0..<Self.sessions {
                Self.session(&areas, sync: { samples, pane in
                    Self.frame(&samples) {
                        if copyOut {
                            var scroll = areaScrolls[area.id] ?? ScrollAreaScroll()
                            scroll.state.reduce(.sync(scroll.strip(area), focused: pane, source: .keyboard, animated: true))
                            areaScrolls[area.id] = scroll
                        } else {
                            // As ScreenContentView+ScrollAreas: no local copy holds the value while it reduces.
                            if areaScrolls[area.id] == nil { areaScrolls[area.id] = ScrollAreaScroll() }
                            guard let areaStrip = areaScrolls[area.id]?.strip(area) else { return }
                            areaScrolls[area.id]?.state.reduce(.sync(areaStrip, focused: pane, source: .keyboard, animated: true))
                        }
                    }
                }, reduce: { event in
                    if copyOut, var scroll = areaScrolls[area.id] {
                        scroll.state.reduce(event)
                        areaScrolls[area.id] = scroll
                    } else {
                        areaScrolls[area.id]?.state.reduce(event)
                    }
                }, step: { areaScrolls[area.id]?.state.spring.advance(Self.dt, parameters: Self.spring, epsilon: 0.25) ?? false },
                focus: areaFocus, round: round)
            }
            Self.report(copyOut ? "area (copy out)" : "area (in place)", areas)
        }
        #expect(!columns.isEmpty)
    }
}
