public import CmuxNextDesignTokens

/// `ui.animations.newTab` (bool, default true: a new tab grows in at its slot;
/// Lawrence 2026-10-14) and `ui.animations.newWorkspace` (bool, default true: a new row opens
/// at its index on the rows' spring and the rows below slide; Lawrence 2026-10-16) and
/// `ui.animations.bounce` ("none" or "subtle") in cmux.json
/// (plans/cmux-next/motion.md). They apply under `ui.animationSpeed`:
/// "off" or Reduce Motion stops every kind whatever these say. Pane layout
/// is `ui.paneAnimations` (`PaneAnimationsSetting`).
public nonisolated struct AnimationKindsSetting: Sendable, Equatable {
    /// Kinds whose `ui.animations.<kind>` is true.
    public var enabled: Set<MotionKind> = AnimationKindsSetting.defaultEnabled
    /// `ui.animations.bounce`.
    public var bounce: MotionBounce = AnimationKindsSetting.bounceFallback

    /// The kinds on when cmux.json does not name them: new tabs and new workspaces.
    public static let defaultEnabled: Set<MotionKind> = [.newTab, .newWorkspace]

    public init(enabled: Set<MotionKind> = AnimationKindsSetting.defaultEnabled, bounce: MotionBounce = AnimationKindsSetting.bounceFallback) {
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
        var enabled = defaultEnabled
        var diagnostics: [SettingsDiagnostic] = []
        for kind in MotionKind.allCases {
            guard let value = root.value(at: path(kind)) else { continue }
            guard let on = value.boolValue else {
                diagnostics.append(SettingsDiagnostic(kind: .invalidValue, path: path(kind).joined(separator: "."), message: "expected true or false"))
                continue
            }
            if on { enabled.insert(kind) } else { enabled.remove(kind) }
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
