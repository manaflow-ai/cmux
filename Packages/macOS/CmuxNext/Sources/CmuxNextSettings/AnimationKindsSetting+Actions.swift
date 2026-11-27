public import CmuxNextActions
public import CmuxNextDesign

extension AnimationKindsSetting {
    /// The palette actions of `ui.animations.*`: `appearance.animations.<kind>.toggle` flips a
    /// kind (its default removes the key). A managed key refuses and changes nothing.
    @MainActor public static func bindActions(into registry: ActionRegistry, design: DesignSettings, save: @escaping SettingChoiceActions.Save) {
        for kind in MotionKind.allCases {
            registry.bind(ActionID(rawValue: "appearance.animations.\(kind.rawValue).toggle"), invoke: { [weak registry] _ in
                let on = !design.enabledAnimations.contains(kind)
                if let refusal = save(path(kind), on == defaultEnabled.contains(kind) ? nil : .bool(on)) {
                    registry?.refuse(refusal)
                    return
                }
                if on { design.enabledAnimations.insert(kind) } else { design.enabledAnimations.remove(kind) }
            })
            ActionTargetTitles.setPaletteSettingState(ActionID(rawValue: "appearance.animations.\(kind.rawValue).toggle"), in: registry) { design.enabledAnimations.contains(kind) }
        }
    }
}
