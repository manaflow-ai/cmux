import Foundation

/// Native execution mode, which never implies an activity transition.
public enum CmuxSidebarAgentMode: String, Codable, CaseIterable, Equatable, Sendable {
    /// No trustworthy mode event is known.
    case unknown
    /// The agent is planning; this alone does not request plan review.
    case plan
    /// The agent uses execution mode; OpenCode build mode maps here.
    case execution

    /// Decodes an additive future value conservatively as unknown.
    /// - Parameter decoder: The wire decoder.
    /// - Throws: A decoding error when the value is not a string.
    public init(from decoder: any Decoder) throws {
        self = Self(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unknown
    }
}
