import AppKit
import CmuxNextTestSupport
import Darwin
import Foundation
@testable import CmuxNextLayout
import Testing
import QuartzCore

/// Pane layout motion replayed through the real layout path with stub pane content
/// (CMUX_PANE_BENCH=1; panes-perf, Lawrence 2026-10-21). A grid of `columns` x `rows` panes in
/// a 1600 x 1000 window; each action is one daemon layout (`LayoutModel.apply`), then display
/// frames until the springs rest. Each frame runs what one display frame runs: the model's
/// observation turn, `advanceFrame`, layout and display. Per frame it records wall time; the
/// budget is the frame at 120 Hz (8.33 ms). Stub content isolates our layout work from
/// terminal and page content (the fleet's pane-perf run measures those).
@MainActor
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["CMUX_PANE_BENCH"] == "1"), .closesItsWindows)
struct PaneMotionBench {
    static let frameBudget = 1.0 / 120
    /// The layout's own share of a frame: what is left for content, Core Animation and the GPU.
    static let layoutBudget = 0.004

    final class Panes: LayoutPaneContentProvider {
        func makeContentView(for pane: PaneID) -> NSView {
            let view = NSView()
            view.wantsLayer = true
            return view
        }
    }

    final class Harness {
        let provider = Panes()
        let model: LayoutModel
        let root: LayoutRootView
        let window: NSWindow

        init(_ screens: [LayoutScreen], focused: PaneID) {
            model = LayoutModel(screens: screens, activeScreenID: "s", focusedPane: focused)
            root = LayoutRootView(model: model, contentProvider: provider)
            root.context.reduceMotionOverride = false
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1600, height: 1000), styleMask: [.borderless],
                              backing: .buffered, defer: false)
            window.contentView = root
            root.layoutSubtreeIfNeeded()
        }

        /// One display frame's work; returns its wall time and whether anything still moves.
        func frame() async -> (seconds: Double, moving: Bool) {
            // The model's observation turn (the reconcile a change causes) counts toward the frame.
            let start = CACurrentMediaTime()
            for _ in 0..<4 { await Task.yield() }
            let moving = root.advanceFrame(PaneMotionBench.frameBudget)
            root.layoutSubtreeIfNeeded()
            root.displayIfNeeded()
            return (CACurrentMediaTime() - start, moving)
        }

        /// Applies `screens` and runs frames until rest (at most 2 s of frames). The first frame
        /// carries the reconcile the change caused (the model's observation turn runs in it).
        func run(_ screens: [LayoutScreen], focus: PaneID? = nil) async -> [Double] {
            model.apply(screens: screens)
            // New Column focuses its pane, and the strip camera reveals it (the app's newColumn).
            if let focus { model.focus(focus, notify: false) }
            var times: [Double] = []
            var moving = true
            while moving, times.count < 240 {
                let next = await frame()
                times.append(next.seconds)
                moving = next.moving
            }
            return times
        }
    }

    /// A column of `rows` panes stacked by vertical splits.
    static func column(_ index: Int, rows: Int, width: Double) -> LayoutColumn {
        func stack(_ from: Int) -> SplitNode {
            let pane = PaneID("p\(index)-\(from)")
            guard from < rows - 1 else { return .leaf(pane) }
            return .split(SplitID("s\(index)-\(from)"), axis: .vertical, ratio: 1 / Double(rows - from), a: .leaf(pane), b: stack(from + 1))
        }
        return LayoutColumn(id: ColumnID("c\(index)"), width: width, root: stack(0))
    }

    static func grid(_ columns: Int, _ rows: Int, extraColumn: Bool = false, zoomed: Bool = false) -> [LayoutScreen] {
        let width = 1.0 / Double(columns)
        var list = (0..<columns).map { column($0, rows: rows, width: width) }
        if extraColumn { list.append(column(columns, rows: 1, width: width)) }
        let layout: ScreenLayout = zoomed ? .splits(.leaf(PaneID("p0-0"))) : .columns(list)
        return [LayoutScreen(id: "s", name: "s", layout: layout, zoomed: zoomed)]
    }

    /// The same grid with the first pane split right (Cmd-D) or down (Cmd-Shift-D).
    static func split(_ columns: Int, _ rows: Int, axis: SplitAxis) -> [LayoutScreen] {
        var screens = grid(columns, rows)
        guard case var .columns(list) = screens[0].layout else { return screens }
        let first = list[0]
        func replace(_ node: SplitNode) -> SplitNode {
            switch node {
            case let .leaf(pane) where pane == PaneID("p0-0"):
                return .split(SplitID("new"), axis: axis, ratio: 0.5, a: .leaf(pane), b: .leaf(PaneID("new")))
            case .leaf:
                return node
            case let .split(id, splitAxis, ratio, a, b):
                return .split(id, axis: splitAxis, ratio: ratio, a: replace(a), b: replace(b))
            }
        }
        list[0] = LayoutColumn(id: first.id, width: first.width, root: replace(first.root))
        screens[0].layout = .columns(list)
        return screens
    }

    static func percentile(_ values: [Double], _ p: Double) -> Double {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return 0 }
        return sorted[min(sorted.count - 1, Int((Double(sorted.count - 1) * p).rounded()))]
    }

    struct Case: CustomTestStringConvertible, Sendable {
        let name: String
        let columns: Int
        let rows: Int
        var testDescription: String { "\(name) \(columns)x\(rows)" }
    }

    nonisolated static let cases: [Case] = [(1, 2), (4, 2), (6, 5)].flatMap { size in
        ["split", "splitDown", "close", "column", "columnClose", "zoom", "unzoom"].map { Case(name: $0, columns: size.0, rows: size.1) }
    }

    @Test(arguments: cases)
    func paneActionFitsTheFrame(_ bench: Case) async {
        let (c, r) = (bench.columns, bench.rows)
        let (before, after): ([LayoutScreen], [LayoutScreen]) = switch bench.name {
        case "split": (Self.grid(c, r), Self.split(c, r, axis: .horizontal))
        case "splitDown": (Self.grid(c, r), Self.split(c, r, axis: .vertical))
        case "close": (Self.split(c, r, axis: .horizontal), Self.grid(c, r))
        case "column": (Self.grid(c, r), Self.grid(c, r, extraColumn: true))
        case "columnClose": (Self.grid(c, r, extraColumn: true), Self.grid(c, r))
        case "zoom": (Self.grid(c, r), Self.grid(c, r, zoomed: true))
        default: (Self.grid(c, r, zoomed: true), Self.grid(c, r))
        }
        var times: [Double] = []
        for _ in 0..<3 {
            // Column close starts focused on the column it closes, so the camera springs back.
            let harness = Harness(before, focused: bench.name == "columnClose" ? PaneID("p\(c)-0") : PaneID("p0-0"))
            defer { harness.window.closeAfterTest() }
            _ = await harness.frame()
            times += await harness.run(after, focus: bench.name == "column" ? PaneID("p\(c)-0") : nil)
        }
        let p50 = Self.percentile(times, 0.5), p95 = Self.percentile(times, 0.95), max = times.max() ?? 0
        let over = times.filter { $0 > Self.frameBudget }.count
        let ms = { (value: Double) in String(format: "%.3f", value * 1000) }
        print("PANE-BENCH action=\(bench.name) panes=\(c * r) frames=\(times.count) p50_ms=\(ms(p50)) p95_ms=\(ms(p95)) max_ms=\(ms(max)) over_8ms=\(over)")
        #expect(times.count > 3, "\(bench) moved: \(times.count) frames")
        #expect(p95 <= Self.layoutBudget, "\(bench): layout frame p95 \(ms(p95)) ms over \(ms(Self.layoutBudget)) ms")
        #expect(max <= Self.frameBudget, "\(bench): layout frame max \(ms(max)) ms over one 120 Hz frame")
    }
}
