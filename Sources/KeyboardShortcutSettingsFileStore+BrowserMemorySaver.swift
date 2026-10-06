import CmuxBrowser
import CmuxSettings
import Foundation

/// Settings-file parsing for the browser Memory Saver keys, extracted from
/// `KeyboardShortcutSettingsFileStore.swift`, which sits at its file-length budget.
extension CmuxSettingsFileStore {
    /// Applies `browser.hiddenWebViewDiscardMode`, `browser.hiddenWebViewMemoryBudgetMB`
    /// and `browser.hiddenWebViewDiscardDelaySeconds`. Returns `false` for an invalid
    /// delay so the caller keeps its existing behavior of skipping the rest of the
    /// browser section.
    func parseBrowserMemorySaverSettings(
        _ section: [String: Any],
        sourcePath: String,
        snapshot: inout ResolvedSettingsSnapshot
    ) -> Bool {
        if section.keys.contains("hiddenWebViewDiscardMode") {
            if let raw = jsonString(section["hiddenWebViewDiscardMode"]),
               let mode = BrowserHiddenWebViewDiscardMode(rawValue: raw) {
                snapshot.managedUserDefaults[BrowserHiddenWebViewDiscardPolicy.modeKey] = .string(mode.rawValue)
            } else {
                logInvalid("browser.hiddenWebViewDiscardMode", sourcePath: sourcePath)
            }
        }
        if section.keys.contains("hiddenWebViewMemoryBudgetMB") {
            if let value = jsonInt(section["hiddenWebViewMemoryBudgetMB"]),
               let budget = BrowserHiddenWebViewDiscardPolicy.resolvedMemoryBudgetMB(value) {
                snapshot.managedUserDefaults[BrowserHiddenWebViewDiscardPolicy.memoryBudgetKey] = .int(budget)
            } else {
                logInvalid("browser.hiddenWebViewMemoryBudgetMB", sourcePath: sourcePath)
            }
        }
        if let value = jsonDouble(section["hiddenWebViewDiscardDelaySeconds"]) {
            guard let delay = BrowserHiddenWebViewDiscardPolicy.resolvedHiddenDelay(value) else {
                logInvalid("browser.hiddenWebViewDiscardDelaySeconds", sourcePath: sourcePath)
                return false
            }
            snapshot.managedUserDefaults[BrowserHiddenWebViewDiscardPolicy.hiddenDelayKey] = .double(delay)
        }
        return true
    }
}
