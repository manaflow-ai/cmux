import Foundation

/// Table-driven descriptor mapping a string JSON settings key to its managed
/// `UserDefaults` key.
public struct SettingsFileStringMapping {
    public let jsonKey: String
    public let defaultsKey: String

    public init(jsonKey: String, defaultsKey: String) {
        self.jsonKey = jsonKey
        self.defaultsKey = defaultsKey
    }
}
