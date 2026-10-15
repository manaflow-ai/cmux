import Foundation

/// A secret name a repository declares it needs.
public struct CloudSecretRequirement: Hashable, Sendable {
    public let name: String
    public let description: String?
    /// The declaring file, relative to the repository root (`.cmux/cloud.json`).
    public let source: String

    public init(name: String, description: String?, source: String) {
        self.name = name
        self.description = description
        self.source = source
    }
}
