import Foundation

/// Repository for the app UI language, persisted in `UserDefaults` under the
/// catalog's `app.language` key, plus cmux-owned writes to the system
/// `AppleLanguages` per-app override.
///
/// `AppleLanguages` is the OS-defined per-app language override list that
/// Foundation's localization machinery reads at process start. cmux writes a
/// single-element list when the user chooses an explicit app language, and
/// records that write in a companion key so returning to
/// ``AppLanguage/system`` removes only an override cmux still owns. Launch
/// reconciliation repairs missing cmux overrides for explicit selections but
/// never deletes externally-managed `AppleLanguages` values.
///
/// Isolation: a stateless `Sendable` struct, not an actor — its operations run
/// synchronously at startup, from Settings, or from the settings importer, the
/// struct holds no mutable state, and `UserDefaults` is documented thread-safe.
public struct LanguageSettingsStore: Sendable {
    // UserDefaults is documented thread-safe and the reference is immutable.
    private nonisolated(unsafe) let defaults: UserDefaults
    private let keys = AppCatalogSection()
    private let domainName: String?
    private let appleLanguagesKey = "AppleLanguages"
    private let appliedOverrideKey = "appLanguageAppliedOverride"

    /// Creates a store reading and writing the given defaults suite.
    ///
    /// Pass `domainName` for any non-`.standard` suite so ownership checks
    /// read only that suite's persistent domain; without it, reads fall back
    /// to the defaults search list, which inherits `NSGlobalDomain` values.
    public init(defaults: UserDefaults, domainName: String? = nil) {
        self.defaults = defaults
        self.domainName = domainName ?? (defaults === UserDefaults.standard ? Bundle.main.bundleIdentifier : nil)
    }

    /// The persisted language choice; unrecognized stored values read as
    /// ``AppLanguage/system``.
    public var storedLanguage: AppLanguage {
        keys.language.value(in: defaults)
    }

    /// Writes an explicit cmux-owned `AppleLanguages` override, or removes it
    /// for ``AppLanguage/system`` only when the current value still matches
    /// cmux's last recorded write.
    public func applyLanguageOverride(_ language: AppLanguage) {
        if language == .system {
            if let appliedOverride = defaults.string(forKey: appliedOverrideKey), currentAppleLanguages == [appliedOverride] {
                defaults.removeObject(forKey: appleLanguagesKey)
            }
            defaults.removeObject(forKey: appliedOverrideKey)
        } else {
            defaults.set([language.rawValue], forKey: appleLanguagesKey)
            defaults.set(language.rawValue, forKey: appliedOverrideKey)
        }
    }

    /// Repairs or adopts cmux-owned explicit overrides at launch without
    /// removing or replacing externally-managed `AppleLanguages` values.
    public func reconcileLanguageOverrideAtLaunch() {
        let language = storedLanguage
        guard language != .system else { return }

        let expectedOverride = [language.rawValue]
        if let currentAppleLanguages {
            guard currentAppleLanguages == expectedOverride else { return }
            if defaults.string(forKey: appliedOverrideKey) == nil {
                defaults.set(language.rawValue, forKey: appliedOverrideKey)
            }
        } else {
            applyLanguageOverride(language)
        }
    }

    private var currentAppleLanguages: [String]? {
        if let domainName {
            return defaults.persistentDomain(forName: domainName)?[appleLanguagesKey] as? [String]
        }
        return defaults.array(forKey: appleLanguagesKey) as? [String]
    }
}
