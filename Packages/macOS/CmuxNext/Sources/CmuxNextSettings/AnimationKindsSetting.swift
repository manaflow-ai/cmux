public import CmuxNextDesign

/// `ui.animations.{newTab,newWorkspace}` (bool, default false: the change
/// applies in one frame; true opts into its spring) and
/// `ui.animations.bounce` ("none" or "subtle") in cmux.json
/// (plans/cmux-next/motion.md). They apply under `ui.animationSpeed`:
/// "off" or Reduce Motion stops every kind whatever these say. Pane layout
/// is `ui.paneAnimations` (`PaneAnimationsSetting`).
public nonisolated struct AnimationKindsSetting: Sendable, Equatable {
    /// Kinds whose `ui.animations.<kind>` is true.
    public var enabled: Set<MotionKind> = []
    /// `ui.animations.bounce`.
    public var bounce: MotionBounce = AnimationKindsSetting.bounceFallback

    public init(enabled: Set<MotionKind> = [], bounce: MotionBounce = AnimationKindsSetting.bounceFallback) {
        self.enabled = enabled
        self.bounce = bounce
    }

    public static let bouncePath = ["ui", "animations", "bounce"]
    public static let bounceFallback: MotionBounce = .none

    /// `ui.animations.<kind>`.
    public static func path(_ kind: MotionKind) -> [String] { ["ui", "animations", kind.rawValue] }

    /// The kinds turned on and the bounce. A missing key is its default
    /// with no diagnostic; a bad value is the default plus a diagnostic.
    static func parse(_ root: JSONValue) -> (AnimationKindsSetting, [SettingsDiagnostic]) {
        var enabled: Set<MotionKind> = []
        var diagnostics: [SettingsDiagnostic] = []
        for kind in MotionKind.allCases {
            guard let value = root.value(at: path(kind)) else { continue }
            guard let on = value.boolValue else {
                diagnostics.append(SettingsDiagnostic(kind: .invalidValue, path: path(kind).joined(separator: "."), message: "expected true or false"))
                continue
            }
            if on { enabled.insert(kind) }
        }
        var bounce = bounceFallback
        if let value = root.value(at: bouncePath) {
            if let text = value.stringValue, let parsed = MotionBounce(rawValue: text) {
                bounce = parsed
            } else {
                let choices = MotionBounce.allCases.map { "\"\($0.rawValue)\"" }.joined(separator: ", ")
                diagnostics.append(SettingsDiagnostic(kind: .invalidValue, path: "ui.animations.bounce", message: "expected one of \(choices)"))
            }
        }
        return (AnimationKindsSetting(enabled: enabled, bounce: bounce), diagnostics)
    }
}
