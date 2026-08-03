import CmuxFoundation
import CmuxSettings
import Foundation

/// Reset behavior shared by the native settings controller and tests.
@MainActor
public struct ResetSection {
    private let defaultsStore: UserDefaultsSettingsStore
    private let jsonStore: JSONConfigStore
    private let catalog: SettingCatalog
    private let hostActions: SettingsHostActions

    /// Creates a reset section backed by the provided stores and host actions.
    ///
    /// - Parameters:
    ///   - defaultsStore: Store that clears UserDefaults-backed settings.
    ///   - jsonStore: Store that clears JSON-backed settings.
    ///   - catalog: Catalog containing every setting the reset action covers.
    ///   - hostActions: Host callbacks for app-owned live-refresh side effects.
    public init(
        defaultsStore: UserDefaultsSettingsStore,
        jsonStore: JSONConfigStore,
        catalog: SettingCatalog,
        hostActions: SettingsHostActions
    ) {
        self.defaultsStore = defaultsStore
        self.jsonStore = jsonStore
        self.catalog = catalog
        self.hostActions = hostActions
    }

    func resetAll() async {
        await defaultsStore.resetAll(catalog.all)
        for key in catalog.all {
            await key.resetInJSON(jsonStore)
        }
        await defaultsStore.resetAllLegacyShortcutBindings()
        hostActions.notifyShortcutSettingsDidChange()
        NotificationCenter.default.post(name: GlobalFontMagnification.didChangeNotification, object: nil)
        hostActions.resetAllSettingsSideEffects()
    }
}
