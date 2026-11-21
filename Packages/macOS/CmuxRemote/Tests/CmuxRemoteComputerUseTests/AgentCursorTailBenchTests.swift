// SPDX-License-Identifier: GPL-3.0-or-later
import CoreGraphics
import Foundation
import QuartzCore
import Testing
@testable import CmuxRemoteComputerUse

/// What one idle batch costs the main thread when it starts: stepping the model ahead and making
/// each frame's path and the white edge's outline (its shadow). Prints the median of 50 runs for
/// a few batch lengths; with CMUX_TAIL_BENCH unset it only checks the work is done.
@MainActor
@Suite struct AgentCursorTailBenchTests {
    @Test func idleBatchCost() {
        let runs = ProcessInfo.processInfo.environment["CMUX_TAIL_BENCH"] == nil ? 2 : 50
        for frames in [120, 60, 30] {
            var steps: [Double] = [], outlines: [Double] = []
            for run in 0..<runs {
                var tail = AgentCursorTail(session: "bench-\(run)", animates: true)
                let clock = ContinuousClock()
                var paths: [CGPath] = []
                let stepped = clock.measure {
                    paths = tail.advance(frames: frames, dt: 1.0 / 60, pointer: CGPoint(x: 10, y: 10), speed: 1, scale: 1.3)
                }
                var count = 0
                let outlined = clock.measure {
                    for path in paths {
                        count += path.copy(strokingWithWidth: 5.6, lineCap: .round, lineJoin: .round, miterLimit: 10).isEmpty ? 0 : 1
                    }
                }
                #expect(count == frames)
                steps.append(Double(stepped.components.attoseconds) / 1e15 + Double(stepped.components.seconds) * 1000)
                outlines.append(Double(outlined.components.attoseconds) / 1e15 + Double(outlined.components.seconds) * 1000)
            }
            let median = { (values: [Double]) in values.sorted()[values.count / 2] }
            print(String(format: "tail-bench frames=%d step+path %.3f ms, outlines %.3f ms, total %.3f ms (median of %d)",
                         frames, median(steps), median(outlines), median(steps) + median(outlines), runs))
        }
    }

    /// The whole main-thread spike of starting a batch in the real overlay (stepping ahead, paths,
    /// shadow outlines, the keyframe animations), on a test screen: the median over 30 batches.
    @Test func overlayBatchStartCost() {
        let screen = AgentCursorScreen(frame: CGRect(x: 0, y: 0, width: 800, height: 600), scale: 2)
        let overlay = AgentCursorOverlay(reduceMotion: { false }, screens: { [screen] })
        overlay.show(AgentCursorEvent(kind: .move, session: "bench", label: "Claude", at: CGPoint(x: 200, y: 200)))
        guard let probe = overlay.tailProbe(session: "bench") else {
            Issue.record("no cursor")
            return
        }
        let clock = ContinuousClock()
        var t = CACurrentMediaTime()
        var spikes: [Double] = []
        let target = ProcessInfo.processInfo.environment["CMUX_TAIL_BENCH"] == nil ? 2 : 30
        for _ in 0..<target {
            // Bounded: a tail that never calms down fails the suite instead of hanging it.
            for _ in 0..<Int(10 * 60) where !probe.batching {
                t += 1.0 / 60
                let cost = clock.measure { probe.frame(at: t) }
                if probe.batching { spikes.append(Double(cost.components.attoseconds) / 1e15 + Double(cost.components.seconds) * 1000) }
            }
            guard probe.batching else {
                Issue.record("the tail never played ahead within 10 s of calm frames")
                break
            }
            // A key press in place stirs it; then it calms and plays ahead again.
            overlay.show(AgentCursorEvent(kind: .keys, session: "bench", label: "Claude", at: CGPoint(x: 200, y: 200), text: "a"))
        }
        #expect(spikes.count == target)
        let sorted = spikes.sorted()
        print(String(format: "tail-bench overlay batch start (%d frames): median %.3f ms, max %.3f ms over %d batches",
                     AgentCursorTailDriver.batchFrames, sorted[sorted.count / 2], sorted.last ?? 0, sorted.count))
        overlay.hideAll()
    }
}
