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
/// reconciliation repairs missing or stale cmux overrides for explicit
/// selections but never deletes externally-managed `AppleLanguages` values.
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
    /// read only that suite's persistent domain; it defaults to the main
    /// bundle identifier, which matches the `.standard` suite's app domain.
    public init(defaults: UserDefaults, domainName: String? = Bundle.main.bundleIdentifier) {
        self.defaults = defaults
        self.domainName = domainName
    }

    /// The persisted language choice; unrecognized stored values read as
    /// ``AppLanguage/system``.
    public var storedLanguage: AppLanguage {
        keys.language.value(in: defaults)
    }

    /// Writes an explicit cmux-owned `AppleLanguages` override, or removes it
    /// for ``AppLanguage/system`` only when the current value still matches
    /// cmux's last recorded write.
    ///
    /// A no-companion `AppleLanguages` value is never removed, even though a
    /// pre-companion cmux build could have left one behind when its last
    /// session switched to System: those bytes are indistinguishable from a
    /// user's manual `defaults write` or the macOS per-app Language & Region
    /// setting, and deleting them is the exact data loss of
    /// https://github.com/manaflow-ai/cmux/issues/7686. The legacy leftover
    /// self-heals when the user picks any explicit language (or toggles
    /// through one back to System), which stamps the companion.
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

    /// Repairs, adopts, or refreshes cmux-owned explicit overrides at launch,
    /// and clears stale cmux-owned overrides for ``AppLanguage/system`` without
    /// removing externally-managed `AppleLanguages` values.
    public func reconcileLanguageOverrideAtLaunch() {
        let language = storedLanguage
        guard language != .system else {
            applyLanguageOverride(.system)
            return
        }

        let expectedOverride = [language.rawValue]
        if let currentAppleLanguages {
            if currentAppleLanguages == expectedOverride {
                if defaults.string(forKey: appliedOverrideKey) == nil {
                    defaults.set(language.rawValue, forKey: appliedOverrideKey)
                }
            } else if let appliedOverride = defaults.string(forKey: appliedOverrideKey), currentAppleLanguages == [appliedOverride] {
                applyLanguageOverride(language)
            } else {
                return
            }
        } else {
            applyLanguageOverride(language)
        }
    }

    // Optional (not `[]`) on purpose: `nil` distinguishes "no AppleLanguages
    // key present" from "present but different value" for the repair branch
    // in reconcileLanguageOverrideAtLaunch(). Do not collapse to [].
    private var currentAppleLanguages: [String]? {
        if let domainName {
            return defaults.persistentDomain(forName: domainName)?[appleLanguagesKey] as? [String]
        }
        return defaults.array(forKey: appleLanguagesKey) as? [String]
    }
}
