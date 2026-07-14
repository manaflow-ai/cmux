import Testing
@testable import CmuxGit

@Suite struct PullRequestChecksStatusTests {
    @Test func emptyRollupHasNoChecks() {
        #expect(PullRequestChecksStatus.derive(from: []) == .noChecks)
    }

    @Test(arguments: ["FAILURE", "TIMED_OUT", "CANCELLED", "ACTION_REQUIRED"])
    func blockingConclusionWinsOverSuccess(_ conclusion: String) {
        let checks = [
            GitHubPullRequestRollupCheck(status: "COMPLETED", conclusion: "SUCCESS"),
            GitHubPullRequestRollupCheck(status: "COMPLETED", conclusion: conclusion),
        ]
        #expect(PullRequestChecksStatus.derive(from: checks) == .failure)
    }

    @Test func incompleteOrMissingConclusionIsPending() {
        let incomplete = [GitHubPullRequestRollupCheck(status: "IN_PROGRESS", conclusion: nil)]
        let missingConclusion = [GitHubPullRequestRollupCheck(status: "COMPLETED", conclusion: nil)]
        #expect(PullRequestChecksStatus.derive(from: incomplete) == .pending)
        #expect(PullRequestChecksStatus.derive(from: missingConclusion) == .pending)
    }

    @Test func successWinsOnlyAfterFailureAndPendingAreAbsent() {
        let checks = [
            GitHubPullRequestRollupCheck(status: "COMPLETED", conclusion: "NEUTRAL"),
            GitHubPullRequestRollupCheck(status: "COMPLETED", conclusion: "SUCCESS"),
        ]
        #expect(PullRequestChecksStatus.derive(from: checks) == .success)
    }

    @Test func completedNeutralChecksProduceNeutralRollup() {
        let checks = [GitHubPullRequestRollupCheck(status: "COMPLETED", conclusion: "NEUTRAL")]
        #expect(PullRequestChecksStatus.derive(from: checks) == .neutral)
    }

    @Test func statusContextStateParticipatesInRollup() {
        let checks = [GitHubPullRequestRollupCheck(status: nil, conclusion: nil, state: "FAILURE")]
        #expect(PullRequestChecksStatus.derive(from: checks) == .failure)

        let expected = [GitHubPullRequestRollupCheck(status: nil, conclusion: nil, state: "EXPECTED")]
        #expect(PullRequestChecksStatus.derive(from: expected) == .pending)
    }
}
