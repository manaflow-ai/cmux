import Foundation

/// The stable identity used to bind a stall to one managed provider session.
public struct AgentStallSessionIdentity: Equatable, Sendable {
    /// Canonical provider identifier, such as `claude` or `codex`.
    public let provider: String
    /// Provider-specific session or checkpoint identifier.
    public let checkpointID: String

    /// Creates a session identity after trimming its fields.
    ///
    /// - Parameters:
    ///   - provider: Canonical or alias provider identifier.
    ///   - checkpointID: Provider session/checkpoint identifier.
    public init(provider: String, checkpointID: String) {
        self.provider = AgentStallClassifier.canonicalProvider(provider)
        self.checkpointID = checkpointID.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Whether the identity contains enough information to prove ownership.
    public var isComplete: Bool {
        !provider.isEmpty && !checkpointID.isEmpty
    }
}
