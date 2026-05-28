import CmuxSettings
import Foundation

/// Application-wide instances of the new `CmuxSettings` stores + catalog.
///
/// The new settings architecture (under `Packages/CmuxSettings`) is built
/// on dependency injection: there are no shared singletons inside the
/// package. The app constructs one ``SettingCatalog``, one
/// ``UserDefaultsSettingsStore``, and one ``JSONConfigStore`` at startup
/// and injects them into every consumer.
///
/// This file is the single, app-owned location where those instances
/// live. It is *not* part of the package — it is the app-side glue that
/// resolves the package's DI seam to the production runtime.
///
/// The instances are created lazily on first access of
/// ``AppSettingsRuntime/shared`` and live for the lifetime of the
/// process. Consumers that want a different lifecycle (e.g. tests) can
/// construct their own instances directly via the package API.
@MainActor
enum AppSettingsRuntime {
    /// The single catalog of cmux settings keys.
    static let catalog = SettingCatalog()

    /// UserDefaults-backed store. Runs legacy-key migrations against
    /// `UserDefaults.standard` at first access of this property.
    static let userDefaultsStore: UserDefaultsSettingsStore = {
        UserDefaultsSettingsStore(
            defaults: .standard,
            migrating: catalog.all
        )
    }()

    /// JSON-config-backed store. Defaults to the standard cmux config path.
    static let jsonConfigStore: JSONConfigStore = {
        let locations = CmuxConfigLocation()
        return JSONConfigStore(fileURL: locations.userConfigFile)
    }()
}
