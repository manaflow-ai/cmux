public import CmuxNextDesign

/// The motion switches in cmux.json (plans/cmux-next/motion-DESIGN.md):
/// `ui.animations.enabled`, the master switch (bool, default true: false makes
/// every animation in the app instant), and one `ui.animations.<category>`
/// per ``MotionCategory`` (bool, default true: false makes that area instant).
/// Settings > Appearance > Motion shows them; Cmd-Shift-P, the CLI and MCP
/// toggle them (`appearance.animations.toggle`,
/// `appearance.animations.<category>.toggle`).
///
/// They apply on top of `ui.animationSpeed` and the system Reduce Motion:
/// an animation runs only when the master switch is on, its category is on,
/// the speed is not "off", and Reduce Motion allows it.
public nonisolated struct MotionCategoriesSetting: Sendable, Equatable {
    /// `ui.animations.enabled`.
    public var enabled: Bool
    /// The categories whose `ui.animations.<category>` is false.
    public var disabled: Set<MotionCategory>

    public init(enabled: Bool = MotionCategoriesSetting.enabledDefault, disabled: Set<MotionCategory> = MotionCategoriesSetting.defaultDisabled) {
        self.enabled = enabled
        self.disabled = disabled
    }

    // The paths and defaults (every switch on) are generated from schemas/settings/source/motion.json.

    /// The categories off when cmux.json does not name them (none).
    public static let defaultDisabled = Set(MotionCategory.allCases.filter { !isOnByDefault($0) })

    /// Whether `category` is on when cmux.json does not name it.
    public static func isOnByDefault(_ category: MotionCategory) -> Bool {
        switch category {
        case .sidebar: sidebarDefault
        case .tabs: tabsDefault
        case .panes: panesDefault
        case .overlays: overlaysDefault
        case .hoverCards: hoverCardsDefault
        case .home: homeDefault
        case .cursor: cursorDefault
        case .indicators: indicatorsDefault
        case .feedback: feedbackDefault
        case .web: webDefault
        }
    }

    /// `ui.animations.<category>`.
    public static func path(_ category: MotionCategory) -> [String] { ["ui", "animations", category.configKey] }

    /// The master switch and the categories turned off. A missing key is its
    /// default with no diagnostic; a value that is not a bool is the default
    /// plus a diagnostic.
    static func parse(_ root: JSONValue) -> (MotionCategoriesSetting, [SettingsDiagnostic]) {
        var setting = MotionCategoriesSetting()
        var diagnostics: [SettingsDiagnostic] = []
        if let value = root.value(at: enabledPath) {
            if let on = value.boolValue {
                setting.enabled = on
            } else {
                diagnostics.append(SettingsDiagnostic(kind: .invalidValue, path: enabledPath.joined(separator: "."), message: "expected true or false"))
            }
        }
        for category in MotionCategory.allCases {
            guard let value = root.value(at: path(category)) else { continue }
            guard let on = value.boolValue else {
                diagnostics.append(SettingsDiagnostic(kind: .invalidValue, path: path(category).joined(separator: "."), message: "expected true or false"))
                continue
            }
            if on { setting.disabled.remove(category) } else { setting.disabled.insert(category) }
        }
        return (setting, diagnostics)
    }
}
