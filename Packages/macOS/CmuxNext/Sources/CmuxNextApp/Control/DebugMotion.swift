import CmuxNextDesign
import CmuxNextSettings
import CmuxNextWakeups

/// `debug.motion`: `start` begins recording animation spans, `read` returns
/// them, `stop` returns them and stops. Each span runs from an animation's
/// first frame to rest (plans/cmux-next/motion.md "Verification").
/// `speed` with `value` ("fast", "normal", "off") sets the live speed in
/// memory only, so a bench can compare speeds without writing cmux.json; the
/// next cmux.json load restores the file's value. `reduce` with `value` true or
/// false overrides Reduce Motion in memory (null follows the system setting
/// again), so a bench records reduced motion without the system setting.
/// `bounce` with `value` ("none", "subtle") and `kind` with `name` ("splits",
/// "newTab", "newWorkspace") and `value` true or false set `ui.animations.*`
/// in memory the same way. The report lists the display links alive
/// (`display_links`: 0 once every spring rests, so the window idles).
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
        case "bounce":
            if let value = params["value"]?.stringValue, let bounce = MotionBounce(rawValue: value) {
                DesignSettings.shared.animationBounce = bounce
            }
        case "kind":
            if let name = params["name"]?.stringValue, let kind = MotionKind(rawValue: name), let on = params["value"]?.boolValue {
                if on { DesignSettings.shared.disabledAnimations.remove(kind) } else { DesignSettings.shared.disabledAnimations.insert(kind) }
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
            "bounce": .string(policy.bounce.rawValue),
            "disabled_kinds": .array(policy.disabledKinds.map(\.rawValue).sorted().map(JSONValue.string)),
            "display_links": .number(Double(FrameScheduler.all.filter(\.hasLink).count)),
            "active_clients": .array(FrameScheduler.all.flatMap(\.activeClients).map(JSONValue.string)),
            "spans": .array(MotionTrace.spans.map { span in
                ["name": .string(span.name), "ms": .number((span.milliseconds * 10).rounded() / 10)]
            }),
        ]
    }
}
