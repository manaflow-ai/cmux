import struct CmuxBrowser.BrowserThemeSettings
import CmuxSettings
import Foundation

/// Stateless parser for the `browser` section of a cmux settings JSON root.
///
/// Projects the decoded `browser` object into a ``ResolvedSettingsSnapshot``:
/// the default/custom search-engine selection, the boolean and string browser
/// toggles, the `theme` mode, and the hidden-webview discard delay. It reuses
/// the `CmuxSettings` decoders that own the browser value shapes
/// (``BrowserSearchEngine``, ``BrowserSearchSettingsStore`` for search-engine
/// normalization, ``BrowserThemeMode``/``BrowserThemeSettings`` for theming,
/// ``BrowserHiddenWebViewDiscardPolicy`` for the discard delay) and the shared
/// ``SettingsFileProjectionEngine`` for the table-driven applies, JSON scalar
/// coercion, and invalid-setting logging. It holds no paths and touches no
/// filesystem; ``SettingsFileParser`` constructs it with its projection engine
/// and forwards the section once per source file.
struct BrowserSettingsFileSectionParser {
    private let projection: SettingsFileProjectionEngine

    init(projection: SettingsFileProjectionEngine) {
        self.projection = projection
    }

    func parse(
        _ section: [String: Any],
        sourcePath: String,
        snapshot: inout ResolvedSettingsSnapshot
    ) {
        let browserSearchSettings = BrowserSearchSettingsStore()

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
        projection.applyBooleanSettings(BrowserSettingsFileMapping.booleanSettings, from: section, sourcePath: sourcePath, into: &snapshot)
        projection.applyStringSettings(BrowserSettingsFileMapping.stringSettings, from: section, into: &snapshot)
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
        projection.applyNormalizedStringArraySettings(BrowserSettingsFileMapping.stringArraySettings, from: section, sourcePath: sourcePath, into: &snapshot)
    }

    // The domain-agnostic projection engine (table-driven apply, invalid-setting
    // logging, JSON scalar coercion) lives in `CmuxSettings`. This parser holds the
    // same instance its owner (`SettingsFileParser`) holds and forwards the shared
    // `logInvalid`/`json*` helpers to it so the moved call sites stay unchanged.
    private func logInvalid(_ path: String, sourcePath: String) {
        projection.logInvalid(path, sourcePath: sourcePath)
    }

    private func jsonString(_ rawValue: Any?) -> String? {
        projection.jsonString(rawValue)
    }

    private func jsonDouble(_ rawValue: Any?) -> Double? {
        projection.jsonDouble(rawValue)
    }
}
