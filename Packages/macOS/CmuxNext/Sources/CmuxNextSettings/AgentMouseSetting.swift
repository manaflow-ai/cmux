/// `browser.agentMouse.motion` and `browser.agentMouse.maxMoveMs`: how an
/// agent's pointer moves in browser tabs (plans/cmux-next/human-mouse-DESIGN.md).
public nonisolated struct AgentMouseSetting: Sendable {
    /// How an agent's pointer moves.
    public enum Motion: String, Sendable, Hashable, CaseIterable {
        /// A person's path: curved, slow-fast-slow, a rest before each press.
        case human
        /// One jump to the target and an instant press, the fastest.
        case instant
    }

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

    /// The motion key's path in cmux.json.
    public let motionPath = ["browser", "agentMouse", "motion"]
    /// The cap key's path in cmux.json.
    public let maxMoveMsPath = ["browser", "agentMouse", "maxMoveMs"]
    /// The values while the keys are absent: human motion, 350 ms cap.
    public let fallback = Value(motion: .human, maxMoveMs: 350)
    /// The cap's accepted range in ms.
    public let maxMoveMsRange: ClosedRange<Double> = 60...1_000

    /// The setting's paths and defaults.
    public init() {}

    /// Absent keys keep the default; a bad value keeps it too, with a diagnostic.
    func parse(_ root: JSONValue) -> (Value, [SettingsDiagnostic]) {
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
