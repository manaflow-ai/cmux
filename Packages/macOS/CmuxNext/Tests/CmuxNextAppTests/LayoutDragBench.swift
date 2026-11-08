import AppKit
import CmuxNextTestSupport
import Darwin
import Foundation
@testable import CmuxNextLayout
import Testing

/// A pane drag replayed through the real layout path (CMUX_DRAG_BENCH=1;
/// scripts/measure/perf-10x-drag.sh). Three columns, the first split in two;
/// each gesture is 360 pointer moves (120 Hz for 3 s) on a real
/// `DividerHandleView`, and each move runs what one display frame runs: the
/// handle's drag event, the model's observation turn, `advanceFrame`, layout and
/// display. Per move it records wall time and main-thread CPU time; a move over
/// 8.33 ms is a dropped 120 Hz frame. `intents` counts the layout intents the
/// gesture emitted for the daemon (the app sends one daemon command per
/// intent, at most one in flight per gesture).
@MainActor
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["CMUX_DRAG_BENCH"] == "1"), .closesItsWindows)
struct LayoutDragBench {
    nonisolated static let rounds = Int(ProcessInfo.processInfo.environment["CMUX_DRAG_BENCH_ROUNDS"] ?? "") ?? 3
    static let moves = 360
    static let frameBudget = 1.0 / 120

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
        var changed = 0
        var ended = 0

        init() {
            let columns = [
                LayoutColumn(id: "c0", width: 0.5, root: .split("x", axis: .horizontal, ratio: 0.5, a: .leaf("p1"), b: .leaf("p2"))),
                LayoutColumn(id: "c1", width: 0.5, root: .split("y", axis: .vertical, ratio: 0.5, a: .leaf("p3"), b: .leaf("p4"))),
                LayoutColumn(id: "c2", width: 0.5, root: .leaf("p5")),
            ]
            model = LayoutModel(screens: [LayoutScreen(id: "s", name: "s", layout: .columns(columns))], activeScreenID: "s",
                                focusedPane: "p1")
            root = LayoutRootView(model: model, contentProvider: provider)
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1600, height: 1000), styleMask: [.borderless],
                              backing: .buffered, defer: false)
            window.contentView = root
            root.layoutSubtreeIfNeeded()
            model.intentHandler = { [unowned self] intent in
                switch intent {
                case .setSplitRatio(_, _, _, let phase), .setColumnWidth(_, _, _, _, let phase):
                    if phase == .ended { ended += 1 } else { changed += 1 }
                default: break
                }
            }
        }

        var screen: ScreenContentView { root.screenViews["s"]! }

        func event(_ type: NSEvent.EventType, _ point: CGPoint) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                               context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }

        /// One display frame's work after a pointer change.
        func frame() async {
            for _ in 0..<4 { await Task.yield() }
            _ = root.advanceFrame(LayoutDragBench.frameBudget)
            root.layoutSubtreeIfNeeded()
            root.displayIfNeeded()
        }
    }

    struct Sample {
        var wall: [Double] = []
        var cpu: [Double] = []
    }

    private static func threadCPU() -> Double {
        var spec = timespec()
        clock_gettime(CLOCK_THREAD_CPUTIME_ID, &spec)
        return Double(spec.tv_sec) + Double(spec.tv_nsec) / 1e9
    }

    private static func percentile(_ values: [Double], _ p: Double) -> Double {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return 0 }
        return sorted[min(sorted.count - 1, Int((Double(sorted.count - 1) * p).rounded()))]
    }

    /// Drags `kind`'s handle back and forth by ±`amplitude` points.
    private func drag(_ harness: Harness, _ kind: DividerHandleView.Kind, center: CGPoint, axisX: Bool) async -> Sample {
        let handle = harness.screen.dividerViews[kind]!
        let start = harness.screen.convert(center, to: nil)
        handle.mouseDown(with: harness.event(.leftMouseDown, start))
        await harness.frame()
        var sample = Sample()
        let amplitude: CGFloat = 120
        var point = start
        for move in 1...Self.moves {
            let offset = amplitude * CGFloat(sin(Double(move) / Double(Self.moves) * 2 * .pi * 3))
            point = axisX ? CGPoint(x: start.x + offset, y: start.y) : CGPoint(x: start.x, y: start.y + offset)
            let wall0 = CACurrentMediaTime(), cpu0 = Self.threadCPU()
            handle.mouseDragged(with: harness.event(.leftMouseDragged, point))
            await harness.frame()
            sample.wall.append(CACurrentMediaTime() - wall0)
            sample.cpu.append(Self.threadCPU() - cpu0)
        }
        handle.mouseUp(with: harness.event(.leftMouseUp, point))
        await harness.frame()
        return sample
    }

    private func report(_ name: String, _ samples: [Sample], intents: Int, ended: Int, rounds: Int) {
        let wall = samples.flatMap(\.wall), cpu = samples.flatMap(\.cpu)
        let dropped = wall.filter { $0 > Self.frameBudget }.count
        let ms = { (value: Double) in String(format: "%.3f", value * 1000) }
        let perSecond = Double(intents) / (Double(rounds) * Double(Self.moves) / 120)
        print("DRAG-BENCH gesture=\(name) n=\(wall.count) frame_p50_ms=\(ms(Self.percentile(wall, 0.5))) frame_p95_ms=\(ms(Self.percentile(wall, 0.95)))"
            + " frame_max_ms=\(ms(wall.max() ?? 0)) main_cpu_p50_ms=\(ms(Self.percentile(cpu, 0.5))) main_cpu_p95_ms=\(ms(Self.percentile(cpu, 0.95)))"
            + " dropped=\(dropped) live_intents=\(intents) live_intents_per_s=\(String(format: "%.1f", perSecond)) ended_intents=\(ended)")
    }

    @Test func dividerAndColumnEdgeDrags() async {
        for (name, kind) in [("split", DividerHandleView.Kind.split("x")), ("column", .columnEdge(ColumnID("c0")))] {
            var samples: [Sample] = []
            var intents = 0, ended = 0
            for _ in 0..<Self.rounds {
                let harness = Harness()
                defer { harness.window.closeAfterTest() }
                let screen = harness.screen
                let center: CGPoint
                switch kind {
                case .split:
                    let divider = screen.geometry.dividers.first { $0.id == "x" }!
                    center = CGPoint(x: divider.frame.midX + screen.stripShift, y: divider.frame.midY)
                default:
                    let frame = screen.geometry.columns["c0"]!
                    center = CGPoint(x: frame.maxX + screen.context.style.stripGap / 2 + screen.stripShift, y: frame.midY)
                }
                samples.append(await drag(harness, kind, center: center, axisX: true))
                intents += harness.changed
                ended += harness.ended
            }
            report(name, samples, intents: intents, ended: ended, rounds: Self.rounds)
        }
    }
}
