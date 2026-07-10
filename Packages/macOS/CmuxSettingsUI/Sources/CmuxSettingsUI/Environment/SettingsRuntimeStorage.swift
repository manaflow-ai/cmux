import CmuxSettings

/// Immutable reference storage keeps `SettingsRuntime` cheap to copy through
/// SwiftUI environment values while preserving its read-only public contract.
final class SettingsRuntimeStorage {
    let catalog: SettingCatalog
    let searchIndex: SettingsSearchIndex
    let userDefaultsStore: UserDefaultsSettingsStore
    let jsonStore: JSONConfigStore
    let secretStore: SecretFileStore
    let errorLog: SettingsErrorLog
    let accountFlow: AccountFlow?
    let hostActions: SettingsHostActions

    @MainActor
    init(
        catalog: SettingCatalog,
        userDefaultsStore: UserDefaultsSettingsStore,
        jsonStore: JSONConfigStore,
        secretStore: SecretFileStore,
        errorLog: SettingsErrorLog,
        accountFlow: AccountFlow?,
        hostActions: SettingsHostActions,
        searchIndex: SettingsSearchIndex?
    ) {
        self.catalog = catalog
        self.searchIndex = searchIndex ?? SettingsSearchIndex(catalog: catalog)
        self.userDefaultsStore = userDefaultsStore
        self.jsonStore = jsonStore
        self.secretStore = secretStore
        self.errorLog = errorLog
        self.accountFlow = accountFlow
        self.hostActions = hostActions
    }
}
