import Foundation

public struct CmuxExtensionLocalizedText: Codable, Equatable, Hashable, Sendable {
    public var key: String
    public var defaultValue: String

    public init(key: String, defaultValue: String) {
        self.key = key
        self.defaultValue = defaultValue
    }
}
