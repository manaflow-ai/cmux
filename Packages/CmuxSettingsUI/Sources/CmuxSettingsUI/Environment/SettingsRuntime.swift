import CmuxSettings
import SwiftUI

/// The app-side bundle of catalog + stores + error log, injected into
/// the SwiftUI environment so views can pick up settings dependencies
/// without threading them through every `init`.
///
/// `SettingsRuntime` is a value-typed handle (the stores it holds are
/// actors and the error log is a `@MainActor` class, so the bundle
/// itself is `Sendable`). Construct one at app startup and pass it via
/// ``View/settingsRuntime(_:)``.
public struct SettingsRuntime: Sendable {
    public let catalog: SettingCatalog
    public let userDefaultsStore: UserDefaultsSettingsStore
    public let jsonStore: JSONConfigStore
    public let errorLog: SettingsErrorLog

    public init(
        catalog: SettingCatalog,
        userDefaultsStore: UserDefaultsSettingsStore,
        jsonStore: JSONConfigStore,
        errorLog: SettingsErrorLog
    ) {
        self.catalog = catalog
        self.userDefaultsStore = userDefaultsStore
        self.jsonStore = jsonStore
        self.errorLog = errorLog
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
    /// Injects ``runtime`` into the view tree so any descendant `@Setting`
    /// property wrapper can resolve its store and catalog.
    public func settingsRuntime(_ runtime: SettingsRuntime) -> some View {
        environment(\.settingsRuntime, runtime)
    }
}
