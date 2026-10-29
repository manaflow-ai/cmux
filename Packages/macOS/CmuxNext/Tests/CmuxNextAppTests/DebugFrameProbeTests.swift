@testable import CmuxNextApp
import CmuxNextControl
import CmuxNextDesign
import CmuxNextSettings
import CmuxNextWakeups
import QuartzCore
import Testing

/// `debug.frames`: the render counters add `render_armed` to every reply and their
/// keys only after a counting pass; the frame keys stay as they were.
@MainActor
struct DebugFrameProbeTests {
    /// The reply's keys before RenderStats (p03-rendering-001's base).
    static let frameKeys: Set<String> = [
        "running", "frames", "refresh_ms", "p50_ms", "p95_ms", "p99_ms", "max_ms", "over_16_7_ms", "missed", "missed_at_ms",
        "main_p50_ms", "main_p95_ms", "main_max_ms", "main_total_ms", "main_over_8_3_ms", "view_layouts", "view_layouts_max",
        "window_layouts",
    ]
    static let rawFrameKeys: Set<String> = ["intervals_ms", "main_ms", "view_layouts_per_frame", "window_layouts_per_frame"]

    private func keys(_ reply: ControlReply) -> Set<String>? {
        guard case .value(.object(let members)) = reply else { return nil }
        return Set(members.keys)
    }

    @Test func withoutARenderPassTheReplyAddsOnlyRenderArmed() {
        let probe = DebugFrameProbe(render: RenderFrameLog(stats: RenderStats(), windows: { [] }))
        #expect(keys(probe.handle(["action": .string("read")])) == Self.frameKeys.union(["render_armed"]))
        #expect(keys(probe.handle(["action": .string("read"), "raw": .bool(true)]))
            == Self.frameKeys.union(Self.rawFrameKeys).union(["render_armed"]))
        guard case .value(.object(let members)) = probe.handle(["action": .string("read")]) else {
            Issue.record("debug.frames read did not answer on the main actor")
            return
        }
        #expect(members["render_armed"] == .bool(false))
    }

    /// The run's cap is read on the probes' own frames, with no expiry timer (recipe R-timer):
    /// a frame within ``DebugFrameProbe/maximumRun`` of the run's start is kept, the first one past it ends the run.
    @Test func theFirstFramePastTheRunCapEndsTheRun() {
        let probe = DebugFrameProbe(render: RenderFrameLog(stats: RenderStats(), windows: { [] }))
        #expect(probe.frame(Self.tick(at: 1)), "a frame inside the cap ended the run")
        #expect(!probe.frame(Self.tick(at: DebugFrameProbe.maximumRun + 1)), "a frame past the cap kept the run")
        let cpu = DebugMainCPUProbe()
        #expect(cpu.frame(Self.tick(at: 1)), "a frame inside the cap ended the CPU run")
        #expect(!cpu.frame(Self.tick(at: DebugMainCPUProbe.maximumRun + 1)), "a frame past the cap kept the CPU run")
    }

    private static func tick(at timestamp: CFTimeInterval) -> FrameTick {
        FrameTick(timestamp: timestamp, elapsed: 1.0 / 60, rawElapsed: 1.0 / 60, refreshInterval: 1.0 / 60)
    }
}
