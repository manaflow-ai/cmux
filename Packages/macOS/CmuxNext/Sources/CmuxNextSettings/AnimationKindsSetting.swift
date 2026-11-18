public import CmuxNextDesign

/// `ui.animations.newTab` (bool, default true: a new tab grows in at its slot;
/// Lawrence 2026-10-14) and `ui.animations.newWorkspace` (bool, default true: a new row opens
/// at its index on the rows' spring and the rows below slide; Lawrence 2026-10-16) in cmux.json
/// (plans/cmux-next/motion.md). They apply under `ui.animationSpeed`:
/// "off" or Reduce Motion stops every kind whatever these say. Pane layout
/// is `ui.paneAnimations` (`PaneAnimationsSetting`).
public nonisolated struct AnimationKindsSetting: Sendable, Equatable {
    /// Kinds whose `ui.animations.<kind>` is true.
    public var enabled: Set<MotionKind> = AnimationKindsSetting.defaultEnabled

    /// The kinds on when cmux.json does not name them (new tabs and new workspaces): each kind's
    /// default, generated from schemas/settings/source/appearance.json with the paths.
    public static let defaultEnabled = Set(MotionKind.allCases.filter(isOnByDefault))

    private static func isOnByDefault(_ kind: MotionKind) -> Bool {
        switch kind {
        case .newTab: newTabDefault
        case .newWorkspace: newWorkspaceDefault
        }
    }

    public init(enabled: Set<MotionKind> = AnimationKindsSetting.defaultEnabled) {
        self.enabled = enabled
    }

    /// `ui.animations.<kind>`.
    public static func path(_ kind: MotionKind) -> [String] { ["ui", "animations", kind.rawValue] }

    /// The kinds turned on. A missing key is its default with no
    /// diagnostic; a bad value is the default plus a diagnostic.
    /// `ui.animations.bounce` is retired (schemas/settings/retired-keys.json):
    /// the loader drops it before this runs, whatever its value.
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
        return (AnimationKindsSetting(enabled: enabled), diagnostics)
    }
}
