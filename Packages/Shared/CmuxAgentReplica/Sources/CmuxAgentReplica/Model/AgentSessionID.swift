import Foundation

/// Identifies one agent session within a Mac.
public struct AgentSessionID: Codable, Hashable, Sendable, RawRepresentable {
    /// The opaque session identifier minted by the Mac.
    public let rawValue: String

    /// Creates an agent session identifier.
    /// - Parameter rawValue: The opaque identifier value.
    public init(rawValue: String) {
        self.rawValue = rawValue
    }
}
