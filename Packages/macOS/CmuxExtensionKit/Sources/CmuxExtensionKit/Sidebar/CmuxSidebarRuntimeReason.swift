import Foundation

/// Structured reason for the exact session activity, without prose inference.
public enum CmuxSidebarRuntimeReason: String, Codable, CaseIterable, Equatable, Sendable {
    /// A future or unrecognized native reason.
    case unknown
    /// A permission decision is pending.
    case permission
    /// A user question is pending.
    case question
    /// A plan review decision is pending.
    case planReview
    /// The agent explicitly reported a network retry.
    case networkRetry
    /// The agent explicitly reported waiting for a dependency.
    case dependency
    /// The agent explicitly reported a quota limit.
    case quota
    /// The session explicitly paused or was interrupted.
    case interrupted
    /// The exact session or process ended.
    case processEnded

    /// Decodes an additive future value conservatively as unknown.
    /// - Parameter decoder: The wire decoder.
    /// - Throws: A decoding error when the value is not a string.
    public init(from decoder: any Decoder) throws {
        self = Self(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unknown
    }
}
