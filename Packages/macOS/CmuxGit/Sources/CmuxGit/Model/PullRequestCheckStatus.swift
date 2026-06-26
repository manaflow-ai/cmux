import Foundation

/// Rollup state for a pull request's CI checks.
public enum PullRequestCheckStatus: String, Sendable, Equatable, Decodable {
    /// Checks are absent, queued, in progress, or unavailable.
    case neutral
    /// The check rollup passed.
    case success
    /// The check rollup failed or errored.
    case failure

    /// Maps GitHub GraphQL `statusCheckRollup.state` values to sidebar states.
    public init(githubStatusCheckRollupState rawState: String?) {
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
