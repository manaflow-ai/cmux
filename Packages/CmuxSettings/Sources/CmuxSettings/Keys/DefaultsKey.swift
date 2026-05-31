import Foundation

/// A strongly-typed handle to a setting persisted in `UserDefaults`.
///
/// `DefaultsKey` is one of two key flavors in ``CmuxSettings``; the other is
/// ``JSONKey``. Each flavor only matches its own store, so a
/// ``UserDefaultsSettingsStore`` refuses a ``JSONKey`` at compile time and
/// vice versa. There are no runtime traps for wrong-store mismatches.
///
/// Declare keys on a ``SettingCatalog`` instance and reference them from
/// every call site so the source of truth stays in one place.
///
/// ```swift
/// public let appAppearance = DefaultsKey<AppearanceMode>(
///     id: "app.appearance",
///     defaultValue: .system,
///     userDefaultsKey: "appearanceMode"
/// )
/// ```
public struct DefaultsKey<Value: SettingCodable>: Sendable, Equatable {
    /// The dotted identifier for the setting (e.g. `"app.appearance"`).
    ///
    /// Used for diagnostics, search, and JSON-schema generation. It is
    /// independent of ``userDefaultsKey``, which is the actual UserDefaults
    /// storage key — they may differ for legacy reasons.
    public let id: String

    /// The value returned when no override is stored in the suite.
    public let defaultValue: Value

    /// The actual `UserDefaults` key the value is stored under.
    public let userDefaultsKey: String

    /// Optional `UserDefaults` suite name. `nil` means `UserDefaults.standard`.
    public let suite: String?

    /// UserDefaults keys to migrate from on first read.
    ///
    /// When the primary ``userDefaultsKey`` has no value but a legacy key
    /// does, the legacy value is copied to the primary key and every legacy
    /// key is removed. Use this to retire renamed keys without breaking
    /// existing users.
    public let legacyUserDefaultsKeys: [String]

    /// Creates a UserDefaults-backed setting key.
    ///
    /// - Parameters:
    ///   - id: The dotted identifier (used for diagnostics; usually mirrors
    ///     `userDefaultsKey`, but is allowed to differ).
    ///   - defaultValue: The fallback when no override is stored.
    ///   - userDefaultsKey: The actual UserDefaults key.
    ///   - suite: Optional suite name. `nil` is `UserDefaults.standard`.
    ///   - legacyUserDefaultsKeys: Renamed keys to migrate from on first read.
    public init(
        id: String,
        defaultValue: Value,
        userDefaultsKey: String,
        suite: String? = nil,
        legacyUserDefaultsKeys: [String] = []
    ) {
        self.id = id
        self.defaultValue = defaultValue
        self.userDefaultsKey = userDefaultsKey
        self.suite = suite
        self.legacyUserDefaultsKeys = legacyUserDefaultsKeys
    }
}
