public import CmuxNextActions
public import CmuxNextDesign

/// The appearance actions that write a design setting (animation kinds, motion categories and the
/// background's placement), bound in one call so the app's appearance handler stays a single line.
public struct AppearanceDesignActions {
    public init() {}
    @MainActor public static func bind(into registry: ActionRegistry, design: DesignSettings, save: @escaping SettingChoiceActions.Save) {
        AnimationKindsSetting.bindActions(into: registry, design: design, save: save)
        MotionCategoriesSetting.bindActions(into: registry, design: design, save: save)
        BackdropPlacementSetting.bindActions(into: registry, design: design, save: save)
    }
}
