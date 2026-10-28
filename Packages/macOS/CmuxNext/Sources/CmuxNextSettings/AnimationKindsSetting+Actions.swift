public import CmuxNextActions
public import CmuxNextAppearance
public import CmuxNextDesignTokens

extension AnimationKindsSetting {
    /// The palette actions of `ui.animations.*`: `appearance.animations.<kind>.toggle` flips a
    /// kind (its default removes the key) and `appearance.animations.bounce.<value>` sets the
    /// bounce (none, the default, removes the key). A managed key refuses and changes nothing.
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
        }
        SettingChoiceActions.bind(MotionBounce.allCases, into: registry, id: { "appearance.animations.bounce.\($0.rawValue)" }, path: bouncePath,
                                  fileValue: { $0 == bounceFallback ? nil : .string($0.rawValue) }, save: save) { design.animationBounce = $0 }
    }
}
