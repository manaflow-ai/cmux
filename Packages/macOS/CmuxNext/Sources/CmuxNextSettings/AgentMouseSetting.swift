/// `browser.agentMouse.motion` and `browser.agentMouse.maxMoveMs`: how an
/// agent's pointer moves in browser tabs (plans/cmux-next/human-mouse-DESIGN.md). The paths,
/// defaults, the cap's range and the motions (`AgentMouseMotion`) come from
/// schemas/settings/source/browser.json (SettingsSchema+Browser.generated.swift).
public nonisolated struct AgentMouseSetting: Sendable {
    /// How an agent's pointer moves.
    public typealias Motion = AgentMouseMotion

    /// The parsed setting.
    public struct Value: Sendable, Hashable {
        /// How the pointer moves.
        public var motion: Motion
        /// The longest one move takes, in ms.
        public var maxMoveMs: Double

        /// - Parameters:
        ///   - motion: how the pointer moves.
        ///   - maxMoveMs: the longest one move takes, in ms.
        public init(motion: Motion, maxMoveMs: Double) {
            self.motion = motion
            self.maxMoveMs = maxMoveMs
        }
    }

    /// The values while the keys are absent.
    public static let fallback = Value(motion: motionDefault, maxMoveMs: maxMoveMsDefault)

    public init() {}

    /// Absent keys keep the default; a bad value keeps it too, with a diagnostic.
    static func parse(_ root: JSONValue) -> (Value, [SettingsDiagnostic]) {
        var value = fallback
        var diagnostics: [SettingsDiagnostic] = []
        if let raw = root.value(at: motionPath) {
            if let name = raw.stringValue, let motion = Motion(rawValue: name) {
                value.motion = motion
            } else {
                diagnostics.append(SettingsDiagnostic(kind: .invalidValue, path: "browser.agentMouse.motion", message: "expected \"human\" or \"instant\""))
            }
        }
        if let raw = root.value(at: maxMoveMsPath) {
            if let ms = raw.doubleValue, maxMoveMsRange.contains(ms) {
                value.maxMoveMs = ms
            } else {
                diagnostics.append(SettingsDiagnostic(kind: .invalidValue, path: "browser.agentMouse.maxMoveMs", message: "expected a number from 60 to 1000"))
            }
        }
        return (value, diagnostics)
    }
}
