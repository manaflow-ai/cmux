import CmuxNextImportCards
import CmuxNextSettings

extension AppServices: BrowserImportGateHost {
    var browserImportSettings: SettingsController? { settings }
    func browserImportTurnedOff() { onboarding.importTurnedOff() }
    func setBrowserHistorySyncPaused(_ paused: Bool) async { await onboarding.historySync.setPaused(paused) }
    /// `browser.import.enabled`; on while settings are not loaded.
    var browserImportEnabled: Bool { BrowserImportGate(host: self).isEnabled }
}
