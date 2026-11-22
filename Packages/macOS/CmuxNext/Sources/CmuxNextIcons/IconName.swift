/// The name of a cmux icon, such as `action.close`. The generated members
/// (`IconName.actionClose`, `IconName.catalog`) live in the generated IconName+Members.swift and IconName+Catalog.swift.
public nonisolated struct IconName: RawRepresentable, Hashable, Sendable, Codable {
    public let rawValue: String

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    public init(rawValue: String) {
        self.rawValue = rawValue
    }
}
