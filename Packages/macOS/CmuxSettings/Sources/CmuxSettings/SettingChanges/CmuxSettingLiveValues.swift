import Foundation

/// Where a setting change finds the value cmux is using for a key that
/// cmux.json doesn't set.
///
/// Most settings are stored in UserDefaults by the Settings window; cmux.json
/// only overrides them. So when the file doesn't name a key, `toggle` and
/// `cycle` must start from the UserDefaults value, not the schema default,
/// or the first press would write the value the user already sees.
public struct CmuxSettingLiveValues: Sendable {
    private let resolve: @Sendable (String) -> CmuxSettingValue?

    /// A resolver backed by a closure from a dotted settings path to its
    /// current value, or nil when it has none.
    public init(resolve: @escaping @Sendable (String) -> CmuxSettingValue?) {
        self.resolve = resolve
    }

    /// No live values: absent keys fall back to the schema default.
    public static let schemaDefaultsOnly = CmuxSettingLiveValues { _ in nil }

    /// Reads UserDefaults-backed settings from the defaults domain
    /// `suiteName`, such as the cmux app's bundle identifier when called from
    /// the CLI. `nil` reads `UserDefaults.standard`, which is the app's own
    /// domain inside the app.
    public static func userDefaults(suiteName: String?) -> CmuxSettingLiveValues {
        let keys = Dictionary(
            SettingCatalog().all.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        return CmuxSettingLiveValues { path in
            guard let key = keys[path] else { return nil }
            let defaults = suiteName.flatMap(UserDefaults.init(suiteName:)) ?? .standard
            return key.jsonValueInUserDefaults(defaults).flatMap(CmuxSettingValue.init(jsonObject:))
        }
    }

    func value(at path: String) -> CmuxSettingValue? {
        resolve(path)
    }
}
