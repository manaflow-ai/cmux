import AppKit
@testable import CmuxNextApp
import CmuxNextBridge
import CmuxNextDesign
import CmuxNextDesignTokens
@testable import CmuxNextLayout
import CmuxNextTabs
import CmuxNextTestSupport
import Foundation
import QuartzCore
import Testing

/// FRAME OWNER REFACTOR S1 cost (CMUX_KEY_RESIZE_STRIP_BENCH=1; never in CI): main-thread time of each display frame of
/// keyboard resizes, each resizing strip laid out at its pane's width in every frame (the S1 A/B, switch off 0.066 ms
/// against on 0.276 ms p95, ran before the switch went: job 321ba04adf2ae8d6f0a0ddd9). Three panes in a 1600 x 1000
/// window, each the app's pane content with 6 tabs over stub content; 12 presses alternate Ctrl-Shift-L and H on the
/// middle pane; each frame runs what one display frame runs: `advanceFrame` (springs, pane frames, strip layout), the
/// layout pass, display, the layers' display (what the commit draws: re-truncated tab titles) and the landing's
/// after-commit release. Run optimized on the fleet: package-test-lane.sh suite with CMUX_SWIFT_SUITE_CONFIGURATION=release.
@MainActor
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["CMUX_KEY_RESIZE_STRIP_BENCH"] == "1"), .closesItsWindows)
struct TabStripFollowsPaneTickBench {
    final class Panes: LayoutPaneContentProvider {
        let reveal: LaunchReveal = {
            let reveal = LaunchReveal()
            reveal.markAllReady()
            return reveal
        }()

        func makeContentView(for pane: PaneID) -> NSView {
            let tabs = (0..<6).map { TabItem(id: TabID("\(pane.rawValue)-tab\($0)"), title: "python3 /tmp/sigwinch.py --seed 100\($0)") }
            let view = PaneContentView(stripModel: TabStripModel(tabs: tabs, selectedID: tabs[0].id), reveal: reveal)
            let content = NSView()
            content.wantsLayer = true
            view.show(content)
            return view
        }
    }

    /// What the frame's Core Animation commit draws on the main thread: every layer that needs display draws now (a tab
    /// title re-truncated at a new width redraws its text there).
    static func displayLayers(_ layer: CALayer?) {
        guard let layer else { return }
        layer.displayIfNeeded()
        for sublayer in layer.sublayers ?? [] { displayLayers(sublayer) }
    }

    /// Wall seconds of every frame of `presses` key presses on p2.
    static func run(presses: Int) -> [Double] {
        var times: [Double] = []
        _ = NSApplication.shared
        let columns = [LayoutColumn(id: "c0", width: 1, root: .split("x", axis: .horizontal, ratio: 1.0 / 3, a: .leaf("p1"),
                                                                         b: .split("y", axis: .horizontal, ratio: 0.5, a: .leaf("p2"), b: .leaf("p3"))))]
        let model = LayoutModel(screens: [LayoutScreen(id: "s", name: "s", layout: .columns(columns))], activeScreenID: "s", focusedPane: "p2")
        let provider = Panes()
        let root = LayoutRootView(model: model, contentProvider: provider)
        root.context.reduceMotionOverride = false
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1600, height: 1000), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = root
        defer { window.closeAfterTest() }
        root.layoutSubtreeIfNeeded()
        root.layoutSubtreeIfNeeded()
        root.driver.isManual = true
        var afterCommit: [@MainActor () -> Void] = []
        root.context.afterCommit = { afterCommit.append($0) }
        for press in 0..<presses {
            #expect(PaneResize.press("p2", press.isMultiple(of: 2) ? .right : .left, model: model, view: root))
            var moving = true, frames = 0
            while moving, frames < 240 {
                let start = CACurrentMediaTime()
                moving = root.advanceFrame(1.0 / 120)
                root.layoutSubtreeIfNeeded()
                root.displayIfNeeded()
                Self.displayLayers(root.layer)
                if !moving {
                    let release = afterCommit
                    afterCommit.removeAll()
                    for work in release { work() }
                    root.layoutSubtreeIfNeeded()
                    root.displayIfNeeded()
                    Self.displayLayers(root.layer)
                }
                times.append(CACurrentMediaTime() - start)
                frames += 1
            }
        }
        return times
    }

    static func line(_ name: String, _ times: [Double]) -> String {
        let sorted = times.sorted()
        func ms(_ p: Double) -> String {
            guard !sorted.isEmpty else { return "-" }
            return String(format: "%.3f", sorted[min(sorted.count - 1, Int((p * Double(sorted.count - 1)).rounded()))] * 1000)
        }
        return "KEY-RESIZE-STRIP-BENCH \(name) frames=\(times.count) p50=\(ms(0.5))ms p95=\(ms(0.95))ms p99=\(ms(0.99))ms max=\(ms(1))ms"
    }

    @Test func keyResizeFrameTime() {
        // A warm-up round (first-use costs: fonts, layers), then 5 measured rounds.
        _ = Self.run(presses: 2)
        var times: [Double] = []
        for _ in 0..<5 { times += Self.run(presses: 12) }
        print(Self.line("strip-follows-pane", times))
        #expect(!times.isEmpty)
    }
}
