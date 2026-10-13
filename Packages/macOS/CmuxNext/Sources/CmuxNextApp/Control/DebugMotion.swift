import CmuxNextDesign
import CmuxNextSettings

/// `debug.motion`: `start` begins recording animation spans, `read` returns
/// them, `stop` returns them and stops. Each span runs from an animation's
/// first frame to rest (plans/cmux-next/motion.md "Verification").
/// `speed` with `value` ("fast", "normal", "off") sets the live speed in
/// memory only, so a bench can compare speeds without writing cmux.json; the
/// next cmux.json load restores the file's value. `reduce` with `value` true or
/// false overrides Reduce Motion in memory (null follows the system setting
/// again), so a bench records reduced motion without the system setting.
/// `work` is each timed animation's main-thread work per frame (`MotionTrace.measure`).
enum DebugMotion {
    static func handle(_ params: [String: JSONValue]) -> JSONValue {
        switch params["action"]?.stringValue ?? "read" {
        case "start":
            MotionTrace.start()
        case "speed":
            if let value = params["value"]?.stringValue, let speed = MotionSpeed(rawValue: value) {
                DesignSettings.shared.animationSpeed = speed
            }
        case "reduce":
            Motion.reduceMotionOverride = params["value"]?.boolValue
        case "stop":
            let report = self.report
            MotionTrace.stop()
            return report
        default:
            break
        }
        return report
    }

    private static var report: JSONValue {
        let policy = Motion.policy
        return [
            "recording": .bool(MotionTrace.isEnabled),
            "speed": .string(policy.speed.rawValue),
            "reduce_motion": .bool(policy.reduceMotion),
            "spans": .array(MotionTrace.spans.map { span in
                ["name": .string(span.name), "ms": .number((span.milliseconds * 10).rounded() / 10)]
            }),
            "work": .object(MotionTrace.work.mapValues { frames in
                let sorted = frames.sorted()
                func at(_ p: Double) -> JSONValue { .number(((sorted.isEmpty ? 0 : sorted[Int((Double(sorted.count - 1) * p).rounded())]) * 100).rounded() / 100) }
                return ["frames": JSONValue(sorted.count), "p50_ms": at(0.5), "p95_ms": at(0.95), "max_ms": at(1), "over_4_ms": JSONValue(sorted.filter { $0 > 4 }.count)]
            }),
        ]
    }
}
