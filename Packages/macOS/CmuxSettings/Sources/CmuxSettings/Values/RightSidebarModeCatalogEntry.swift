import Foundation

/// One stable right-sidebar identifier and its accepted CLI spellings.
public struct RightSidebarModeCatalogEntry: Equatable, Identifiable, Sendable {
    /// Persisted right-sidebar mode identifier.
    public let id: String
    /// Canonical spelling used in generated help and forwarded commands.
    public let cliArgument: String
    /// Additional spellings accepted by CLI and socket entry points.
    public let cliAliases: [String]

    /// Creates one catalog entry.
    public init(id: String, cliArgument: String, cliAliases: [String] = []) {
        self.id = id
        self.cliArgument = cliArgument
        self.cliAliases = cliAliases
    }
}
