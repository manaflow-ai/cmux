import Foundation

/// Table-driven descriptor mapping a string-array JSON settings key to its
/// managed `UserDefaults` key, with the dotted path used when logging a present
/// but uncoercible value as invalid.
public struct SettingsFileStringArrayMapping {
    public let jsonKey: String
    public let defaultsKey: String
    public let invalidPath: String

    public init(jsonKey: String, defaultsKey: String, invalidPath: String) {
        self.jsonKey = jsonKey
        self.defaultsKey = defaultsKey
        self.invalidPath = invalidPath
    }
}
