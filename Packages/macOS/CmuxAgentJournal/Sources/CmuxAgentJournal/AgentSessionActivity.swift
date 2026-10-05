/// Semantic activity of one native session, separate from legacy phase.
public enum AgentSessionActivity: String, Codable, Sendable, CaseIterable, Equatable {
    /// No trusted activity assertion.
    case unknown
    /// The session is doing work.
    case working
    /// The turn settled without pending work.
    case idle
    /// A specific user decision is pending.
    case needsInput
    /// The session explicitly reported readiness.
    case ready
    /// An explicit external wait is pending.
    case waiting
    /// An explicit quota condition prevents progress.
    case quotaBlocked
    /// A structured failure prevents progress.
    case failed
    /// The session explicitly paused or was interrupted.
    case paused
    /// The session ended.
    case ended

    /// Decodes unknown additive values conservatively.
    /// - Parameter decoder: Journal wire decoder.
    /// - Throws: A decoding error for non-string values.
    public init(from decoder: any Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        self = Self(rawValue: value) ?? .unknown
    }
}
