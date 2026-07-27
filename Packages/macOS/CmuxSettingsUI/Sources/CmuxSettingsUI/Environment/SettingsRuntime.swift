import CmuxSettings
import SwiftUI

/// The app-side bundle of catalog + stores + error log + account
/// flow delegate, injected into the SwiftUI environment so views can
/// resolve settings dependencies without threading each piece through
/// every `init`.
///
/// `SettingsRuntime` is a value-typed handle: the stores are actors,
/// the error log is a `@MainActor` class, the account flow is a
/// `@MainActor` protocol existential — the bundle itself is
/// `Sendable`. Construct one at app startup and pass it via
/// ``View/settingsRuntime(_:)``.
public struct SettingsRuntime: @unchecked Sendable {
    /// Immutable setting declarations used by stores and section views.
    public let catalog: SettingCatalog
    /// Search index shared by every settings window root for this runtime.
    public let searchIndex: SettingsSearchIndex
    /// UserDefaults-backed settings store.
    public let userDefaultsStore: UserDefaultsSettingsStore
    /// cmux.json-backed settings store.
    public let jsonStore: JSONConfigStore
    /// Secret-file-backed settings store.
    public let secretStore: SecretFileStore
    /// Rolling settings error log displayed as alerts.
    public let errorLog: SettingsErrorLog
    /// Optional host-owned account flow actions.
    public let accountFlow: AccountFlow?
    /// Host callbacks for actions the package cannot perform itself.
    public let hostActions: SettingsHostActions

    /// Creates the settings runtime bundle injected into the settings UI.
    ///
    /// - Parameters:
    ///   - catalog: Immutable setting declarations used by stores and section views.
    ///   - userDefaultsStore: UserDefaults-backed settings store.
    ///   - jsonStore: cmux.json-backed settings store.
    ///   - secretStore: Secret-file-backed settings store.
    ///   - errorLog: Rolling settings error log displayed as alerts.
    ///   - accountFlow: Optional host-owned account flow actions.
    ///   - hostActions: Host callbacks for actions the package cannot perform itself.
    ///   - searchIndex: Prebuilt search index to share across settings roots. When `nil`,
    ///     the runtime builds one index from `catalog` and keeps it for its own lifetime.
    @MainActor
    public init(
        catalog: SettingCatalog,
        userDefaultsStore: UserDefaultsSettingsStore,
        jsonStore: JSONConfigStore,
        secretStore: SecretFileStore,
        errorLog: SettingsErrorLog,
        accountFlow: AccountFlow? = nil,
        hostActions: SettingsHostActions = NoopSettingsHostActions(),
        searchIndex: SettingsSearchIndex? = nil
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

private struct SettingsRuntimeKey: EnvironmentKey {
    static let defaultValue: SettingsRuntime? = nil
}

extension EnvironmentValues {
    /// The settings runtime visible to views via `@Environment`. `nil`
    /// when no runtime has been injected — typically only during
    /// previews and unit tests that don't exercise settings code paths.
    public var settingsRuntime: SettingsRuntime? {
        get { self[SettingsRuntimeKey.self] }
        set { self[SettingsRuntimeKey.self] = newValue }
    }
}

extension View {
    /// Injects ``runtime`` into the view tree so any descendant
    /// `@LiveSetting` property wrapper or settings section can resolve its
    /// store, catalog, and account flow.
    public func settingsRuntime(_ runtime: SettingsRuntime) -> some View {
        environment(\.settingsRuntime, runtime)
    }
}
