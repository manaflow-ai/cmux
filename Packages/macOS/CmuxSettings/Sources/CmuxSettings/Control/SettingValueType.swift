import Foundation

/// The storage backend a catalog setting routes through. Mirrors the three key
/// flavors (``DefaultsKey``, ``JSONKey``, ``SecretFileKey``) so the CLI can
/// report where a value actually lives.
public enum SettingBackend: String, Sendable, Equatable, Codable {
    /// `UserDefaults` (the great majority of settings).
    case userDefaults
    /// The shared `cmux.json` config file.
    case json
    /// A private `0600` secret file (never serialized into `cmux.json`).
    case secret

    /// A short, user-facing label for `list` / `describe` output.
    public var displayName: String {
        switch self {
        case .userDefaults: return "userDefaults"
        case .json: return "cmux.json"
        case .secret: return "secret"
        }
    }
}

/// The shape of a setting's value, derived from its static `Value` type. Drives
/// type-directed CLI parsing, validation messages, and `describe` output —
/// all from catalog metadata, with no per-setting code.
public enum SettingValueType: Sendable, Equatable {
    case bool
    case int
    case double
    case string
    /// An enumeration with a closed set of accepted raw values.
    case enumeration(cases: [String])
    /// A structured value (array or object): collections, shortcut maps, etc.
    case json

    /// A short type name for `describe` / `list --json` output.
    public var name: String {
        switch self {
        case .bool: return "bool"
        case .int: return "int"
        case .double: return "double"
        case .string: return "string"
        case .enumeration: return "enum"
        case .json: return "json"
        }
    }

    /// The accepted raw values when this is an enumeration, else `nil`.
    public var enumCases: [String]? {
        if case let .enumeration(cases) = self { return cases }
        return nil
    }
}
