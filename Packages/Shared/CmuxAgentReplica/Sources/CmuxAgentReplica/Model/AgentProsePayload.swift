import Foundation

/// Carries markdown prose emitted by the agent.
public struct AgentProsePayload: Codable, Hashable, Sendable {
    /// The markdown text to display.
    public let markdown: String

    /// Creates an agent prose payload.
    /// - Parameter markdown: The markdown text to display.
    public init(markdown: String) {
        self.markdown = markdown
    }
}
