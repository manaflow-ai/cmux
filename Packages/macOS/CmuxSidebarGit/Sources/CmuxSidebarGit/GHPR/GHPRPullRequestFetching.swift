/// Fetches one pull-request snapshot from a PRDashboard-compatible source.
public protocol GHPRPullRequestFetching: Sendable {
    func pullRequest(
        _ reference: GHPRPullRequestReference,
        socketPath: String
    ) async throws -> GHPRPullRequestContext?
}
