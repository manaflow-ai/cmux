import Foundation

/// The observed lifecycle of an agent hosted by a sidebar surface.
public enum CmuxSidebarAgentLifecycle: String, Codable, CaseIterable, Equatable, Sendable {
    /// No reliable lifecycle observation is available.
    case unknown
    /// The agent is working on a turn.
    case running
    /// The last turn completed and no input is pending.
    case idle
    /// The agent is waiting for a reply, approval, or other user input.
    case needsInput
    /// The agent reported an error and is not making progress.
    case error

    /// Decodes a lifecycle without interpreting future states as idle.
    ///
    /// - Parameter decoder: Decoder containing a raw lifecycle value.
    /// - Throws: A decoding error if the value is not a string.
    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        self = Self(rawValue: value) ?? .unknown
    }
}
