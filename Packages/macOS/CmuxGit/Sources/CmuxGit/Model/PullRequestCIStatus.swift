import Foundation

/// Rollup CI/check state for a pull request sidebar badge.
public enum PullRequestCIStatus: String, Codable, Sendable, Equatable {
    /// No rollup was fetched, no token was available, checks are pending, or no checks exist.
    case neutral
    /// GitHub reports the pull request's latest commit checks passed.
    case success
    /// GitHub reports the pull request's latest commit checks failed or errored.
    case failure

    /// Maps GitHub GraphQL `statusCheckRollup.state` values to sidebar states.
    public init(statusCheckRollupState rawState: String?) {
        switch rawState?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() {
        case "SUCCESS":
            self = .success
        case "FAILURE", "ERROR":
            self = .failure
        default:
            self = .neutral
        }
    }
}
