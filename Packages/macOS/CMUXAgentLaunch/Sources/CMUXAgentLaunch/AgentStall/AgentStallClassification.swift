import Foundation

/// The immutable result of classifying one managed-agent turn boundary.
public struct AgentStallClassification: Codable, Equatable, Sendable {
    /// Canonical provider ID, such as `claude` or `codex`.
    public let provider: String
    /// Rule that produced the result.
    public let patternIdentifier: String
    /// Stable cause class.
    public let cause: AgentStallCause
    /// Retry or human-action disposition.
    public let disposition: AgentStallDisposition
    /// Stable provider action identifier for callers that resolve input at runtime.
    public let retryActionID: String?
    /// Action identifier for localized human guidance.
    public let suggestedActionID: String

    /// Creates a classification from a matched provider rule.
    ///
    /// - Parameters:
    ///   - provider: Canonical provider identifier.
    ///   - pattern: Rule whose evidence matched the captured output.
    public init(
        provider: String,
        pattern: AgentStallPattern
    ) {
        self.provider = provider
        self.patternIdentifier = pattern.identifier
        self.cause = pattern.cause
        self.disposition = pattern.cause.disposition
        self.retryActionID = pattern.retryActionID
        self.suggestedActionID = pattern.suggestedActionID
    }
}
