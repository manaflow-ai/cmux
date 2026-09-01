import Foundation

/// One data-driven provider output rule used by ``AgentStallClassifier``.
public struct AgentStallPattern: Equatable, Sendable {
    /// Stable identifier used in structured logs and tests.
    public let identifier: String
    /// Canonical provider IDs for which this rule is valid.
    public let providers: Set<String>
    /// Cause emitted when the rule matches.
    public let cause: AgentStallCause
    /// Case-insensitive literal fragments that must all be present.
    public let requiredFragments: [String]
    /// Case-insensitive literal fragments where at least one must be present.
    public let anyFragments: [String]
    /// Optional case-insensitive regular expressions, evaluated after fragments.
    public let regularExpressions: [String]
    /// Stable provider action used to derive the exact prompt input.
    public let retryActionID: String?
    /// Whether a matching banner must also be corroborated by a provider hook.
    ///
    /// Use this for ambiguous short phrases that can occur in ordinary
    /// assistant prose (for example, a standalone "try again later").
    public let requiresStructuredEvidence: Bool
    /// Stable action identifier resolved to localized copy by the app layer.
    public let suggestedActionID: String

    /// Creates a provider rule.
    ///
    /// A rule must supply at least one literal fragment or regular expression;
    /// rules without positive evidence are ignored by ``AgentStallClassifier``.
    ///
    /// - Parameters:
    ///   - identifier: Stable identifier used in logs and tests.
    ///   - providers: Provider identifiers or aliases to which the rule applies.
    ///   - cause: Stable cause emitted when the rule matches.
    ///   - requiredFragments: Literal fragments that must all appear.
    ///   - anyFragments: Literal fragments where at least one must appear.
    ///   - regularExpressions: Regular expressions where at least one must match.
    ///   - retryActionID: Stable provider action identifier for future runtime resolution.
    ///   - requiresStructuredEvidence: Whether a provider hook must corroborate the match.
    ///   - suggestedActionID: Stable identifier for localized human guidance.
    public init(
        identifier: String,
        providers: Set<String>,
        cause: AgentStallCause,
        requiredFragments: [String] = [],
        anyFragments: [String] = [],
        regularExpressions: [String] = [],
        retryActionID: String? = nil,
        requiresStructuredEvidence: Bool = false,
        suggestedActionID: String
    ) {
        self.identifier = identifier
        // Provider aliases are normalized once at the data boundary so custom
        // rules cannot accidentally become unreachable when a hook changes
        // `claude_code` to `claude-code` (or publishes the vendor name).
        self.providers = Set(providers.map(AgentStallClassifier.canonicalProvider))
        self.cause = cause
        self.requiredFragments = requiredFragments
        self.anyFragments = anyFragments
        self.regularExpressions = regularExpressions
        self.retryActionID = retryActionID
        self.requiresStructuredEvidence = requiresStructuredEvidence
        self.suggestedActionID = suggestedActionID
    }
}
