import Foundation

/// Repository for the persisted app-icon mode, stored in `UserDefaults`
/// under the catalog's `app.appIcon` key.
///
/// Only persistence lives here. Applying the icon to the running app
/// (NSApplication, appearance observation, dock tile plugin) is an app-shell
/// service that reads ``resolvedMode`` and stays with the app target until
/// the app-shell package exists.
///
/// Isolation: a stateless `Sendable` struct, not an actor — readers are
/// synchronous launch/apply paths, the struct holds no mutable state, and
/// `UserDefaults` is documented thread-safe.
public struct AppIconSettingsStore: Sendable {
    // UserDefaults is documented thread-safe and the reference is immutable.
    private nonisolated(unsafe) let defaults: UserDefaults
    private let keys = AppCatalogSection()

    /// Creates a store reading the given defaults suite.
    public init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    /// The persisted icon mode; unrecognized stored values read as
    /// ``AppIconMode/automatic``.
    public var resolvedMode: AppIconMode {
        keys.appIcon.value(in: defaults)
    }
}
