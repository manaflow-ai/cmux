public import CmuxNextActions

extension BackdropSelectionSetting {
    /// Switch to Previous Background and Recent Backgrounds… (Leo, 2026-11-22: "it was cumbersome back
    /// then to switch back"): a write of `appearance.background` through `save` (and `appearance.backgroundDynamic` reset from
    /// `time`, so a static pick never inherits sun mode); the settings owner
    /// records the replaced one in appearance.backgroundRecents, so toggling twice comes back. With
    /// nothing earlier (or a pick that is not a background) `openPicker` opens Settings' background
    /// picker, as Change Background… does. Recent Backgrounds… lists the recents by name.
    @MainActor public static func bindRecentActions(
        into registry: ActionRegistry, root: @escaping @MainActor () -> JSONValue,
        save: @escaping SettingChoiceActions.Save, openPicker: @escaping @MainActor (ActionInvocation) throws -> Void
    ) {
        let others = registry.argumentSuggestions
        registry.argumentSuggestions = { source in
            guard source == ActionSuggestions.backgroundRecents else { return others?(source) ?? [] }
            return recents(in: root()).map(recentLabel).map { ActionEnumCase(value: $0.value, title: $0.title, symbol: $0.symbol) }
        }
        let use: @MainActor (String?, ActionInvocation) -> ActionEffect = { raw, invocation in
            guard let raw, accepts(.string(raw)) else {
                do { try openPicker(invocation) } catch { return .refused(String(describing: error)) }
                return .done
            }
            // Sun mode goes off with a recent pick, as the Settings strip and `cmux wallpaper back` do.
            let sunMode = dynamicMode(root()) == .time
            if let refusal = save(configPath, .string(raw)) { return .refused(refusal) }
            if sunMode, let refusal = save(dynamicPath, nil) { return .refused(refusal) }
            return .done
        }
        registry.bindEffect("appearance.previousBackground", effect: { use(previous(in: root()), $0) })
        registry.bindEffect("appearance.recentBackgrounds", effect: { use($0["background"]?.stringValue, $0) })
    }
}
