import Foundation
import CmuxFoundation
import CmuxSettings

extension CmuxSettingsFileStore {
    func parseAppSection(
        _ section: [String: Any],
        sourcePath: String,
        snapshot: inout ResolvedSettingsSnapshot
    ) {
        if let raw = jsonString(section["language"]) {
            guard let language = AppLanguage(rawValue: raw) else {
                logInvalid("app.language", sourcePath: sourcePath)
                return
            }
            snapshot.managedUserDefaults[AppCatalogSection().language.userDefaultsKey] = .string(language.rawValue)
        }
        if let raw = jsonString(section["appearance"]) {
            let normalized = AppearanceSettings.mode(for: raw).rawValue
            let accepted = Set(AppearanceMode.allCases.map(\.rawValue))
            guard accepted.contains(raw) else {
                logInvalid("app.appearance", sourcePath: sourcePath)
                return
            }
            snapshot.managedUserDefaults[AppearanceSettings.appearanceModeKey] = .string(normalized)
        }
        if let raw = jsonString(section["appIcon"]) {
            guard let mode = AppIconMode(rawValue: raw) else {
                logInvalid("app.appIcon", sourcePath: sourcePath)
                return
            }
            snapshot.managedUserDefaults[AppIconSettings.modeKey] = .string(mode.rawValue)
        }
        if let value = jsonBool(section["menuBarOnly"]) {
            snapshot.managedUserDefaults[MenuBarOnlySettings.menuBarOnlyKey] = .bool(value)
            if value {
                snapshot.managedUserDefaults[MenuBarOnlySettings.explicitEnableKey] = .bool(true)
            }
        }
        if let raw = jsonString(section["windowTitleTemplate"]) { snapshot.managedUserDefaults[WindowTitleTemplate.userDefaultsKey] = .string(raw) } else if section.keys.contains("windowTitleTemplate") { logInvalid("app.windowTitleTemplate", sourcePath: sourcePath) }
        if let raw = jsonString(section["newWorkspacePlacement"]) {
            guard let placement = WorkspacePlacement(rawValue: raw) else {
                logInvalid("app.newWorkspacePlacement", sourcePath: sourcePath)
                return
            }
            snapshot.managedUserDefaults[SettingCatalog().app.newWorkspacePlacement.userDefaultsKey] = .string(placement.rawValue)
        }
        if let value = jsonInt(section["globalFontMagnification"]) {
            let clamped = GlobalFontMagnification.clamp(value)
            guard clamped == value else {
                logInvalid("app.globalFontMagnification", sourcePath: sourcePath)
                return
            }
            snapshot.managedUserDefaults[GlobalFontMagnification.percentKey] = .int(clamped)
        } else if section.keys.contains("globalFontMagnification") {
            logInvalid("app.globalFontMagnification", sourcePath: sourcePath)
        }
        if let value = jsonInt(section["paneResizeStepPixels"]) {
            if (PaneResizeStepSettings.minimumPixels...PaneResizeStepSettings.maximumPixels).contains(value) {
                snapshot.managedUserDefaults[PaneResizeStepSettings.key] = .int(value)
            } else {
                logInvalid("app.paneResizeStepPixels", sourcePath: sourcePath)
            }
        } else if section.keys.contains("paneResizeStepPixels") {
            logInvalid("app.paneResizeStepPixels", sourcePath: sourcePath)
        }
        if let raw = jsonString(section["forkConversationDefaultDestination"]) {
            if let destination = AgentConversationForkDestination(rawValue: raw) {
                snapshot.managedUserDefaults[AgentConversationForkDefaultSettings.key] = .string(destination.rawValue)
            } else {
                logInvalid("app.forkConversationDefaultDestination", sourcePath: sourcePath)
            }
        }
        applyBooleanSettings(AppSettingsFileMapping.booleanSettings, from: section, sourcePath: sourcePath, snapshot: &snapshot)
        applyStringSettings(AppSettingsFileMapping.stringSettings, from: section, snapshot: &snapshot)
        if let value = jsonBool(section["minimalMode"]) {
            let mode = value ? WorkspacePresentationModeSettings.Mode.minimal : .standard
            snapshot.managedUserDefaults[WorkspacePresentationModeSettings.modeKey] = .string(mode.rawValue)
        }
        if let value = jsonBool(section["keepWorkspaceOpenWhenClosingLastSurface"]) {
            snapshot.managedUserDefaults[SettingCatalog().app.keepWorkspaceOpenWhenClosingLastSurface.userDefaultsKey] = .bool(!value)
        }
        var parsedConfirmQuitMode: ConfirmQuitMode?
        let confirmQuitKey = AppCatalogSection().confirmQuitMode.userDefaultsKey
        let warnBeforeQuitKey = AppCatalogSection().warnBeforeQuit.userDefaultsKey
        if let raw = jsonString(section["confirmQuit"]) {
            if let mode = ConfirmQuitMode(rawValue: raw) {
                parsedConfirmQuitMode = mode
                snapshot.managedUserDefaults[confirmQuitKey] = .string(mode.rawValue)
            } else {
                logInvalid("app.confirmQuit", sourcePath: sourcePath)
            }
        }
        if let value = jsonBool(section["warnBeforeQuit"]) {
            snapshot.managedUserDefaults[warnBeforeQuitKey] = .bool(value)
            if parsedConfirmQuitMode == nil {
                let mode: ConfirmQuitMode = value ? .always : .never
                snapshot.managedUserDefaults[confirmQuitKey] = .string(mode.rawValue)
                snapshot.legacyDerivedManagedUserDefaultKeys.insert(confirmQuitKey)
            }
        }
    }

}
