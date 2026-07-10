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
    private let storage: SettingsRuntimeStorage

    /// Immutable setting declarations used by stores and section views.
    public var catalog: SettingCatalog {
        _read { yield storage.catalog }
    }
    /// Search index shared by every settings window root for this runtime.
    public var searchIndex: SettingsSearchIndex {
        _read { yield storage.searchIndex }
    }
    /// UserDefaults-backed settings store.
    public var userDefaultsStore: UserDefaultsSettingsStore { storage.userDefaultsStore }
    /// cmux.json-backed settings store.
    public var jsonStore: JSONConfigStore { storage.jsonStore }
    /// Secret-file-backed settings store.
    public var secretStore: SecretFileStore { storage.secretStore }
    /// Rolling settings error log displayed as alerts.
    public var errorLog: SettingsErrorLog { storage.errorLog }
    /// Optional host-owned account flow actions.
    public var accountFlow: AccountFlow? { storage.accountFlow }
    /// Host callbacks for actions the package cannot perform itself.
    public var hostActions: SettingsHostActions { storage.hostActions }

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
        storage = SettingsRuntimeStorage(
            catalog: catalog,
            userDefaultsStore: userDefaultsStore,
            jsonStore: jsonStore,
            secretStore: secretStore,
            errorLog: errorLog,
            accountFlow: accountFlow,
            hostActions: hostActions,
            searchIndex: searchIndex
        )
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
