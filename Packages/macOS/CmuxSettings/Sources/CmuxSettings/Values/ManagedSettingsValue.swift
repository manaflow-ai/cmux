import Foundation

/// A typed value for a managed (administrator-imposed) settings default.
///
/// Each case carries the concrete payload pushed into `UserDefaults` for a
/// managed key, so the store can apply, compare, and persist managed defaults
/// without losing the value's type. Codable conformance is synthesized, matching
/// the on-disk format the store reads and writes for imported managed defaults.
public enum ManagedSettingsValue: Codable, Equatable, Sendable {
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case nullableString(String?)
    case stringArray([String])
    case stringDictionary([String: String])
}
