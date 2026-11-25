import AppKit
@testable import CmuxNextApp
import CmuxNextBridge
import CmuxNextDesign
@testable import CmuxNextLayout
import CmuxNextTabs
@testable import CmuxNextTerminal
import CmuxNextTestSupport
import Foundation
import QuartzCore
import Testing

/// FRAME OWNER REFACTOR S3 cost (CMUX_PANE_BENCH=1, the motion-frame bench switch; never in CI): main-thread time of each
/// display frame of keyboard resizes and closes (each terminal host follows its pane in every frame; a closing pane shows
/// its ground on its collapsing frame). Three panes in a 1600 x 1000 window, each the app's pane content with a real
/// terminal (libghostty surface); 12 presses alternate Ctrl-Shift-L and H on the middle pane, then the middle pane
/// closes. Each frame runs what one display frame runs: `advanceFrame` (springs, pane frames, the containers' layout),
/// the layout pass, display, the layers' display and the landing's after-commit release.
/// Run optimized on the fleet: package-test-lane.sh suite with CMUX_SWIFT_SUITE_CONFIGURATION=release.
/// The numbers with `motion.frameOwner.contentPolicy` off and on before that switch was deleted (one process, interleaved,
/// step 4b4b80b33807e84dbb37cbfc at 2f13aa409db), p50 / p95 / p99 / max: keys off 0.110 / 0.120 / 0.123 / 0.144 ms, on
/// 0.119 / 0.130 / 0.134 / 0.154 ms; close off 0.131 / 0.140 / 0.184 / 0.193 ms, on 0.135 / 0.143 / 0.180 / 0.187 ms.
@MainActor
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["CMUX_PANE_BENCH"] == "1"), .closesItsWindows)
struct PaneContentPolicyBench {
    /// Wall seconds of every frame of `presses` key presses on p2, then a close of p2.
    static func run(presses: Int) throws -> (keys: [Double], close: [Double]) {
        var keys: [Double] = [], close: [Double] = []
        let layout: ScreenLayout = .columns([LayoutColumn(id: "c0", width: 1, root: .split("x", axis: .horizontal, ratio: 1.0 / 3, a: .leaf("p1"),
                                                                                        b: .split("y", axis: .horizontal, ratio: 0.5, a: .leaf("p2"), b: .leaf("p3"))))])
        let rig = PaneGroundCoversPaneTests.Rig(layout, focused: "p2")
        defer { rig.close() }
        rig.window.setContentSize(NSSize(width: 1600, height: 1000))
        rig.root.layoutSubtreeIfNeeded()
        func frames(into times: inout [Double]) {
            var moving = true, count = 0
            while moving, count < 240 {
                let start = CACurrentMediaTime()
                moving = rig.root.advanceFrame(1.0 / 120)
                rig.root.layoutSubtreeIfNeeded()
                rig.root.displayIfNeeded()
                TabStripFollowsPaneTickBench.displayLayers(rig.root.layer)
                if !moving {
                    rig.commit()
                    rig.root.displayIfNeeded()
                    TabStripFollowsPaneTickBench.displayLayers(rig.root.layer)
                }
                times.append(CACurrentMediaTime() - start)
                count += 1
            }
        }
        for press in 0..<presses {
            #expect(PaneResize.press("p2", press.isMultiple(of: 2) ? .right : .left, model: rig.model, view: rig.root))
            rig.root.syncWithModel()
            frames(into: &keys)
        }
        _ = try #require(rig.model.showPaneClose("p2"))
        rig.root.syncWithModel()
        frames(into: &close)
        return (keys, close)
    }

    static func line(_ name: String, _ times: [Double]) -> String {
        TabStripFollowsPaneTickBench.line(name, times).replacingOccurrences(of: "KEY-RESIZE-STRIP-BENCH", with: "CONTENT-POLICY-BENCH")
    }

    @Test func keyResizeAndCloseFrameTime() throws {
        _ = NSApplication.shared
        _ = GhosttyRuntime.shared
        // A warm-up run (first-use costs: fonts, layers, surfaces), then 5 rounds.
        _ = try Self.run(presses: 2)
        var all: (keys: [Double], close: [Double]) = ([], [])
        for _ in 0..<5 {
            let round = try Self.run(presses: 12)
            all.keys += round.keys
            all.close += round.close
        }
        print(Self.line("keys", all.keys))
        print(Self.line("close", all.close))
        #expect(!all.keys.isEmpty && !all.close.isEmpty)
    }
}
