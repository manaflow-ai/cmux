import CmuxNextDesign
import CmuxNextSettings

/// `debug.motion`: `start` begins recording animation spans, `read` returns
/// them, `stop` returns them and stops. Each span runs from an animation's
/// first frame to rest (plans/cmux-next/motion.md "Verification").
/// `speed` with `value` ("fast", "normal", "off") sets the live speed in
/// memory only, so a bench can compare speeds without writing cmux.json; the
/// next cmux.json load restores the file's value.
enum DebugMotion {
    static func handle(_ params: [String: JSONValue]) -> JSONValue {
        switch params["action"]?.stringValue ?? "read" {
        case "start":
            MotionTrace.start()
        case "speed":
            if let value = params["value"]?.stringValue, let speed = MotionSpeed(rawValue: value) {
                DesignSettings.shared.animationSpeed = speed
            }
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
        ]
    }
}
