public import Foundation

/// Stores the pull request handoff snapshot for a Fleet task.
public struct FleetPullRequestStatus: Equatable, Codable, Sendable {
    /// The pull request number from the hosting provider.
    public var number: Int?

    /// The browser URL for the pull request, when known.
    public var url: URL?

    /// The coarse pull request lifecycle state.
    public var state: FleetPullRequestState?

    /// A provider-specific CI summary string reserved for later PRs.
    public var ciSummary: String?

    /// Creates a pull request handoff snapshot.
    /// - Parameters:
    ///   - number: The pull request number from the hosting provider.
    ///   - url: The browser URL for the pull request, when known.
    ///   - state: The coarse pull request lifecycle state.
    ///   - ciSummary: A provider-specific CI summary string reserved for later PRs.
    public init(
        number: Int? = nil,
        url: URL? = nil,
        state: FleetPullRequestState? = nil,
        ciSummary: String? = nil
    ) {
        self.number = number
        self.url = url
        self.state = state
        self.ciSummary = ciSummary
    }

    /// Indicates whether the pull request state is merged or closed.
    public var isTerminal: Bool {
        state?.isTerminal ?? false
    }
}
