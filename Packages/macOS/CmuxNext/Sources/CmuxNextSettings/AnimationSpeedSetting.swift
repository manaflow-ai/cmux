public import CmuxNextDesign

/// `ui.animationSpeed` in cmux.json: "fast" (default), "normal" or "off"
/// (plans/cmux-next/motion.md).
public nonisolated enum AnimationSpeedSetting {
    public static let configPath = ["ui", "animationSpeed"]
    public static let fallback: MotionSpeed = .fast

    /// A missing key is the default with no diagnostic; a bad value is the
    /// default plus a diagnostic.
    static func parse(_ root: JSONValue) -> (MotionSpeed, SettingsDiagnostic?) {
        guard let value = root.value(at: configPath) else { return (fallback, nil) }
        guard let text = value.stringValue, let speed = MotionSpeed(rawValue: text) else {
            let choices = MotionSpeed.allCases.map { "\"\($0.rawValue)\"" }.joined(separator: ", ")
            return (fallback, SettingsDiagnostic(kind: .invalidValue, path: "ui.animationSpeed", message: "expected one of \(choices)"))
        }
        return (speed, nil)
    }
}
