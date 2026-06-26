import Foundation

/// Table-driven descriptor mapping a boolean JSON settings key to its managed
/// `UserDefaults` key, with an optional dotted path used when logging a present
/// but uncoercible value as invalid.
public struct SettingsFileBooleanMapping {
    public let jsonKey: String
    public let defaultsKey: String
    public let invalidPath: String?

    public init(jsonKey: String, defaultsKey: String, invalidPath: String? = nil) {
        self.jsonKey = jsonKey
        self.defaultsKey = defaultsKey
        self.invalidPath = invalidPath
    }
}
