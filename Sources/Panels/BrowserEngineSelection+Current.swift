import CmuxBrowser
import CmuxCore
import CmuxSettings
import Foundation

extension BrowserEngineSelection {
    /// Resolves a production browser-engine selection from the typed settings key and LaunchServices.
    @MainActor
    static func current(
        restoring restoredKind: BrowserEngineKind? = nil,
        defaults: UserDefaults = .standard
    ) -> BrowserEngineSelection {
        let catalog = SettingCatalog()
        let store = UserDefaultsSettingsStore(defaults: defaults)
        let preference = store.initialValue(for: catalog.browser.engine)
        let service = BrowserEngineSelectionService(
            applicationProvider: LaunchServicesBrowserApplicationProvider()
        )
        return service.select(preference: preference, restoredKind: restoredKind)
    }
}
