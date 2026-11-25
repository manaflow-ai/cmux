public import Foundation

/// A managed policy key that is not a cmux.json setting.
public nonisolated struct ManagedPolicyKey: Sendable, Hashable {
    public enum ValueType: Sendable, Hashable {
        case string
        case boolean
        case choice([String])
        case stringArray([String])
    }

    public let name: String
    public let type: ValueType
    public let help: String

    public init(_ name: String, type: ValueType, help: String) {
        self.name = name
        self.type = type
        self.help = help
    }
}
