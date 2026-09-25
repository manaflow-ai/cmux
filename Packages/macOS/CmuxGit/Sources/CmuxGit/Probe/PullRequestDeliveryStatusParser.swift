public import Foundation

/// Decodes GitHub check-run and commit-status payloads into a small UI value.
public struct PullRequestDeliveryStatusParser: Sendable {
    /// Creates a parser.
    public init() {}

    /// Parses the payloads returned by GitHub's check-runs and commit-status APIs.
    ///
    /// The first implementation intentionally reports an unknown state; the
    /// follow-up repair commit supplies the provider decoding and aggregation.
    public func parse(checkRunsData: Data, commitStatusData: Data) -> PullRequestDeliveryStatus {
        PullRequestDeliveryStatus(
            checks: PullRequestCheckSummary(
                state: .unknown,
                passedCount: 0,
                failedCount: 0,
                pendingCount: 0,
                totalCount: 0
            ),
            deployment: nil
        )
    }
}
