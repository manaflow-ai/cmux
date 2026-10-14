public import AppKit

/// `debug.motion` (DEBUG builds register it; `DebugMotion` in CmuxNextApp is its wiring):
/// `start` begins recording animation spans, `read` returns them, `stop` returns them and
/// stops. Each span runs from an animation's first frame to rest (plans/cmux-next/motion.md
/// "Verification"). `speed` with `value` ("fast", "normal", "off") sets the live speed in
/// memory only, so a bench can compare speeds without writing cmux.json; the next cmux.json
/// load restores the file's value. `reduce` with `value` true or false overrides Reduce
/// Motion in memory (null follows the system setting again), so a bench records reduced
/// motion without the system setting. `work` is each timed animation's main-thread work per
/// frame (`MotionTrace.measure`). `trace_start`, `trace_read` and `trace_stop` sample
/// animated geometry on every display frame instead (DEBUG builds, ``MotionFrameTrace``).
/// Takes and returns `JSONSerialization` object graphs.
public struct MotionDebug {
    public init() {}
    /// `samplers` read the animated geometry of the views they know (DEBUG builds: ``MotionFrameTrace``).
    public static func handle(_ params: [String: Any], windows: [NSWindow], samplers: [@MainActor (NSView) -> [String: [Any]]?] = []) -> [String: Any] {
        let action = params["action"] as? String ?? "read"
        #if DEBUG
        if action.hasPrefix("trace_") {
            return MotionFrameTrace.shared.handle(String(action.dropFirst("trace_".count)), params, windows: windows, samplers: samplers)
        }
        #endif
        switch action {
        case "start":
            MotionTrace.start()
        case "speed":
            if let value = params["value"] as? String, let speed = MotionSpeed(rawValue: value) {
                DesignSettings.shared.animationSpeed = speed
            }
        case "reduce":
            Motion.reduceMotionOverride = params["value"] as? Bool
        case "stop":
            let report = self.report
            MotionTrace.stop()
            return report
        default:
            break
        }
        return report
    }

    private static var report: [String: Any] {
        let policy = Motion.policy
        return [
            "recording": MotionTrace.isEnabled,
            "speed": policy.speed.rawValue,
            "reduce_motion": policy.reduceMotion,
            "spans": MotionTrace.spans.map { span -> [String: Any] in
                ["name": span.name, "ms": (span.milliseconds * 10).rounded() / 10]
            },
            "work": MotionTrace.work.mapValues { frames -> [String: Any] in
                let sorted = frames.sorted()
                func at(_ p: Double) -> Double { ((sorted.isEmpty ? 0 : sorted[Int((Double(sorted.count - 1) * p).rounded())]) * 100).rounded() / 100 }
                return ["frames": sorted.count, "p50_ms": at(0.5), "p95_ms": at(0.95), "max_ms": at(1), "over_4_ms": sorted.filter { $0 > 4 }.count]
            },
        ]
    }
}
