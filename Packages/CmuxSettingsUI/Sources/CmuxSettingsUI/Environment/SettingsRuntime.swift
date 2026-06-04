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
    public let catalog: SettingCatalog
    public let userDefaultsStore: UserDefaultsSettingsStore
    public let jsonStore: JSONConfigStore
    public let secretStore: SecretFileStore
    public let errorLog: SettingsErrorLog
    public let accountFlow: AccountFlow?
    public let hostActions: SettingsHostActions

    @MainActor
    public init(
        catalog: SettingCatalog,
        userDefaultsStore: UserDefaultsSettingsStore,
        jsonStore: JSONConfigStore,
        secretStore: SecretFileStore,
        errorLog: SettingsErrorLog,
        accountFlow: AccountFlow? = nil,
        hostActions: SettingsHostActions = NoopSettingsHostActions()
    ) {
        self.catalog = catalog
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
