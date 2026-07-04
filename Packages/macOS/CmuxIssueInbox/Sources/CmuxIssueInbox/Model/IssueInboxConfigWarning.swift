public import Foundation

/// A non-fatal configuration problem recorded while loading Issue Inbox config.
public struct IssueInboxConfigWarning: Codable, Equatable, Sendable, Identifiable {
    /// Stable warning identifier.
    public var id: String
    /// Human-readable warning message.
    public var message: String

    /// Creates a configuration warning.
    ///
    /// - Parameters:
    ///   - id: Stable warning identifier.
    ///   - message: Human-readable warning message.
    public init(id: String, message: String) {
        self.id = id
        self.message = message
    }
}
