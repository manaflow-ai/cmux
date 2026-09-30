import Foundation

/// A pull request associated with an agent session's checkout.
public struct AgentSessionPullRequest: Sendable, Equatable {
    /// Repository-qualified pull request number.
    public let number: Int
    /// Current provider state, such as `OPEN`, `MERGED`, or `CLOSED`.
    public let state: String
    /// Optional pull request title.
    public let title: String?

    public init(number: Int, state: String, title: String? = nil) {
        self.number = number
        self.state = state
        self.title = title
    }
}
