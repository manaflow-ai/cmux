import Foundation

/// Repository for the app UI language, persisted in `UserDefaults` under the
/// catalog's `app.language` key, plus the system `AppleLanguages` override
/// that makes the choice take effect.
///
/// `AppleLanguages` is the OS-defined per-app language override list that
/// Foundation's localization machinery reads at process start; cmux writes a
/// single-element list (or removes the override for
/// ``AppLanguage/system``). The selection therefore applies on next launch,
/// which is why the app reads ``storedLanguage`` once at startup.
///
/// Isolation: a stateless `Sendable` struct, not an actor — both members run
/// synchronously at startup or from the settings importer, the struct holds
/// no mutable state, and `UserDefaults` is documented thread-safe.
public struct LanguageSettingsStore: Sendable {
    // UserDefaults is documented thread-safe and the reference is immutable.
    private nonisolated(unsafe) let defaults: UserDefaults
    private let keys = AppCatalogSection()

    /// Creates a store reading and writing the given defaults suite.
    public init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    /// The persisted language choice; unrecognized stored values read as
    /// ``AppLanguage/system``.
    public var storedLanguage: AppLanguage {
        keys.language.value(in: defaults)
    }

    /// Writes (or, for ``AppLanguage/system``, removes) the `AppleLanguages`
    /// override so `language` takes effect on the next launch.
    public func applyLanguageOverride(_ language: AppLanguage) {
        if language == .system {
            defaults.removeObject(forKey: "AppleLanguages")
        } else {
            defaults.set([language.rawValue], forKey: "AppleLanguages")
        }
    }
}
