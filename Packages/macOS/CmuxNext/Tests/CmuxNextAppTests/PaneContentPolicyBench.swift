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

/// FRAME OWNER REFACTOR S3 cost (CMUX_PANE_BENCH=1, the motion-frame bench switch; never in CI): main-thread time of each display frame of
/// keyboard resizes and closes, with `motion.frameOwner.contentPolicy` off (each terminal host held whole) and on (each
/// terminal host follows its pane in every frame; a closing pane shows its ground on its collapsing frame). Three panes in
/// a 1600 x 1000 window, each the app's pane content with a real terminal (libghostty surface); 12 presses alternate
/// Ctrl-Shift-L and H on the middle pane, then the middle pane closes. Each frame runs what one display frame runs:
/// `advanceFrame` (springs, pane frames, the containers' layout), the layout pass, display, the layers' display and the
/// landing's after-commit release. Both switch values run in one process, interleaved, so the host's noise falls on both.
/// Run optimized on the fleet: package-test-lane.sh suite with CMUX_SWIFT_SUITE_CONFIGURATION=release.
@MainActor
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["CMUX_PANE_BENCH"] == "1"), .closesItsWindows)
struct PaneContentPolicyBench {
    /// Wall seconds of every frame of `presses` key presses on p2, then a close of p2, with the switch `on`.
    static func run(on: Bool, presses: Int) throws -> (keys: [Double], close: [Double]) {
        var keys: [Double] = [], close: [Double] = []
        let layout: ScreenLayout = .columns([LayoutColumn(id: "c0", width: 1, root: .split("x", axis: .horizontal, ratio: 1.0 / 3, a: .leaf("p1"),
                                                                                        b: .split("y", axis: .horizontal, ratio: 0.5, a: .leaf("p2"), b: .leaf("p3"))))])
        let rig = PaneGroundCoversPaneTests.Rig(layout, focused: "p2")
        defer { rig.close() }
        rig.window.setContentSize(NSSize(width: 1600, height: 1000))
        rig.root.layoutSubtreeIfNeeded()
        rig.root.context.contentPolicyOverride = on
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

    @Test func keyResizeAndCloseFrameTimeWithTheSwitchOffAndOn() throws {
        _ = NSApplication.shared
        _ = GhosttyRuntime.shared
        // A warm-up pair (first-use costs: fonts, layers, surfaces), then 5 interleaved rounds of each.
        _ = try Self.run(on: false, presses: 2)
        _ = try Self.run(on: true, presses: 2)
        var off: (keys: [Double], close: [Double]) = ([], []), on: (keys: [Double], close: [Double]) = ([], [])
        for _ in 0..<5 {
            let a = try Self.run(on: false, presses: 12), b = try Self.run(on: true, presses: 12)
            off.keys += a.keys
            off.close += a.close
            on.keys += b.keys
            on.close += b.close
        }
        print(Self.line("keys switch=off", off.keys))
        print(Self.line("keys switch=on", on.keys))
        print(Self.line("close switch=off", off.close))
        print(Self.line("close switch=on", on.close))
        #expect(!off.keys.isEmpty && !on.keys.isEmpty && !off.close.isEmpty && !on.close.isEmpty)
    }
}
