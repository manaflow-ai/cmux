import CmuxSettings
import Foundation

extension CmuxSettingsFileStore {
    func parseBrowserSection(
        _ section: [String: Any],
        sourcePath: String,
        snapshot: inout ResolvedSettingsSnapshot
    ) {
        let browserSearchSettings = BrowserSearchSettingsStore()
        if let raw = section["terminalLinkBrowserPlacement"] {
            if let string = jsonString(raw), let placement = TerminalLinkBrowserPlacement(rawValue: string) {
                snapshot.managedUserDefaults[BrowserCatalogSection().terminalLinkBrowserPlacement.userDefaultsKey] = .string(placement.rawValue)
            } else {
                logInvalid("browser.terminalLinkBrowserPlacement", sourcePath: sourcePath)
            }
        }

        if section.keys.contains("defaultZoomLevel") {
            if let rawZoom = jsonDouble(section["defaultZoomLevel"]), rawZoom.isFinite {
                snapshot.managedUserDefaults[BrowserZoomSettings.userDefaultsKey] = .double(
                    BrowserZoomSettings().normalized(rawZoom)
                )
            } else {
                logInvalid("browser.defaultZoomLevel", sourcePath: sourcePath)
            }
        }

        if let raw = jsonString(section["defaultSearchEngine"]) {
            guard let engine = BrowserSearchEngine(rawValue: raw) else {
                logInvalid("browser.defaultSearchEngine", sourcePath: sourcePath)
                return
            }
            snapshot.managedUserDefaults[BrowserSearchSettingsStore.searchEngineKey] = .string(engine.rawValue)
        }
        if let raw = jsonString(section["customSearchEngineName"]) {
            snapshot.managedUserDefaults[BrowserSearchSettingsStore.customSearchEngineNameKey] = .string(
                browserSearchSettings.normalizedCustomSearchEngineName(raw)
                    ?? BrowserSearchSettingsStore.defaultCustomSearchEngineName
            )
        }
        if let raw = jsonString(section["customSearchEngineURLTemplate"]) {
            if browserSearchSettings.isValidSearchURLTemplate(raw) {
                snapshot.managedUserDefaults[BrowserSearchSettingsStore.customSearchEngineURLTemplateKey] = .string(raw)
            } else {
                logInvalid("browser.customSearchEngineURLTemplate", sourcePath: sourcePath)
            }
        }
        applyBooleanSettings(BrowserSettingsFileMapping.booleanSettings, from: section, sourcePath: sourcePath, snapshot: &snapshot)
        applyStringSettings(BrowserSettingsFileMapping.stringSettings, from: section, snapshot: &snapshot)
        if let raw = jsonString(section["theme"]) {
            guard let mode = BrowserThemeMode(rawValue: raw) else {
                logInvalid("browser.theme", sourcePath: sourcePath)
                return
            }
            snapshot.managedUserDefaults[BrowserThemeSettings.modeKey] = .string(mode.rawValue)
        }
        if let value = jsonDouble(section["hiddenWebViewDiscardDelaySeconds"]) {
            guard let delay = BrowserHiddenWebViewDiscardPolicy.resolvedHiddenDelay(value) else {
                logInvalid("browser.hiddenWebViewDiscardDelaySeconds", sourcePath: sourcePath)
                return
            }
            snapshot.managedUserDefaults[BrowserHiddenWebViewDiscardPolicy.hiddenDelayKey] = .double(delay)
        }
        applyNormalizedStringArraySettings(BrowserSettingsFileMapping.stringArraySettings, from: section, sourcePath: sourcePath, snapshot: &snapshot)
    }
}
