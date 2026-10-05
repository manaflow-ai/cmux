/// Structured native reason for session activity, without message classification.
public enum AgentRuntimeReason: String, Codable, Sendable, CaseIterable, Equatable {
    /// An unrecognized future native reason.
    case unknown
    /// A permission decision is pending.
    case permission
    /// A question is pending.
    case question
    /// A plan review is pending.
    case planReview
    /// The native runtime reported a network retry.
    case networkRetry
    /// The native runtime reported a dependency wait.
    case dependency
    /// The native runtime reported quota exhaustion.
    case quota
    /// The native runtime reported an interruption.
    case interrupted
    /// The exact session ended.
    case processEnded

    /// Decodes unknown additive values conservatively.
    /// - Parameter decoder: Journal wire decoder.
    /// - Throws: A decoding error for non-string values.
    public init(from decoder: any Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        self = Self(rawValue: value) ?? .unknown
    }
}
