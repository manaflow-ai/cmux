import CmuxNextActions
import CmuxNextCompat
import CmuxNextImportCards
import CmuxNextSettings

/// `browser.import.enabled` (Settings > Browser > Import; on by default). Off, cmux's Import from
/// Browser entry points leave: the File menu items, palette actions and context-menu rows below
/// (a run is refused with ``BrowserImportOfferStrings/turnedOff``), the import tool window, the
/// browser tab's import offer and the import suggestion cards on Home, New Tab and Settings ›
/// Import. Nothing imports by itself either: Keep in Sync stops re-reading other browsers' history
/// and a paused card job does not resume. Data already imported stays, and Remove Imported Data
/// still removes it.
@MainActor
struct BrowserImportGate {
    /// The actions that bring data over from another browser or app.
    static let actionIDs: Set<ActionID> = [
        "importFromBrowser", "bookmark.importFromBrowser", "browser.importFromFiles", "browser.importCookies",
        "import.list", "import.card", "import.suggest", "import.open",
    ]

    let services: AppServices

    /// Turns the import actions off in every surface while the setting is off.
    func install(into registry: ActionRegistry) {
        registry.settingOffReason = { [weak services] id in
            guard Self.actionIDs.contains(id), services?.browserImportEnabled == false else { return nil }
            return BrowserImportOfferStrings.turnedOff
        }
    }

    /// Follows the setting: the suggestion cards and Keep in Sync.
    func follow(_ settings: SettingsController) -> Task<Void, Never> {
        // task-owner: OnboardingService.importSettingFollow (cancelled when settings are replaced)
        Task { [weak services] in
            var last: Bool?
            for await on in ObservationStream({ settings.snapshot.browserImportEnabled }) {
                guard let services else { return }
                ImportSuggestionsCenter.shared.importEnabled = on
                // Keep in Sync is made on first use: leave it unmade while import was never off.
                if !on || last == false { await services.onboarding.historySync.setPaused(!on) }
                last = on
            }
        }
    }
}

extension AppServices {
    /// `browser.import.enabled`; on while settings are not loaded.
    var browserImportEnabled: Bool { settings?.snapshot.browserImportEnabled ?? BrowserImportSetting.fallback }
}
