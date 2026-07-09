import Foundation

/// Carries agent thought or reasoning text.
public struct ThoughtPayload: Codable, Hashable, Sendable {
    /// The thought text.
    public let text: String

    /// Creates a thought payload.
    /// - Parameter text: The thought text.
    public init(text: String) {
        self.text = text
    }
}
