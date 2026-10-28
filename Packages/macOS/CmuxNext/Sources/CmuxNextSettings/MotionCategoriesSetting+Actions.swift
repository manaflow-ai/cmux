public import CmuxNextActions
public import CmuxNextAppearance
public import CmuxNextDesignTokens

extension MotionCategoriesSetting {
    /// The palette, CLI and MCP actions of the motion switches:
    /// `appearance.animations.toggle` flips the master switch
    /// `ui.animations.enabled`, and `appearance.animations.<category>.toggle`
    /// flips one category. Turning a switch back on removes its key (the
    /// default). A managed key refuses and changes nothing.
    @MainActor public static func bindActions(into registry: ActionRegistry, design: DesignSettings, save: @escaping SettingChoiceActions.Save) {
        registry.bind(ActionID(rawValue: masterActionID), invoke: { [weak registry] _ in
            let on = !design.animationsEnabled
            if let refusal = save(enabledPath, on == enabledFallback ? nil : .bool(on)) {
                registry?.refuse(refusal)
                return
            }
            design.animationsEnabled = on
        })
        for category in MotionCategory.allCases {
            registry.bind(ActionID(rawValue: actionID(category)), invoke: { [weak registry] _ in
                let on = design.disabledAnimationCategories.contains(category)
                if let refusal = save(path(category), on == categoryFallback ? nil : .bool(on)) {
                    registry?.refuse(refusal)
                    return
                }
                if on { design.disabledAnimationCategories.remove(category) } else { design.disabledAnimationCategories.insert(category) }
            })
        }
    }

    /// The master switch's action.
    public static let masterActionID = "appearance.animations.toggle"

    /// The toggle action of `category`.
    public static func actionID(_ category: MotionCategory) -> String { "appearance.animations.\(category.configKey).toggle" }
}
