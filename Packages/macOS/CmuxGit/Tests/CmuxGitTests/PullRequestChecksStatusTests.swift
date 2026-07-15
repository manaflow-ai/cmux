import Testing
@testable import CmuxGit

@Suite struct PullRequestChecksStatusTests {
    @Test func emptyRollupHasNoChecks() {
        #expect(PullRequestChecksStatus(checks: []) == .noChecks)
    }

    @Test(arguments: [
        "FAILURE", "TIMED_OUT", "CANCELLED", "ACTION_REQUIRED", "ERROR", "STARTUP_FAILURE",
    ])
    func blockingConclusionWinsOverSuccess(_ conclusion: String) {
        let checks = [
            GitHubPullRequestRollupCheck(status: "COMPLETED", conclusion: "SUCCESS"),
            GitHubPullRequestRollupCheck(status: "COMPLETED", conclusion: conclusion),
        ]
        #expect(PullRequestChecksStatus(checks: checks) == .failure)
    }

    @Test(arguments: ["ERROR", "STARTUP_FAILURE"])
    func detailedFailureStateMatchesRollup(_ state: String) {
        let check = GitHubPullRequestCheck(name: "CI", state: state, link: nil)
        #expect(check.presentationState == .failure)
    }

    @Test func staleCheckRemainsPending() {
        let rollup = [GitHubPullRequestRollupCheck(status: "COMPLETED", conclusion: "STALE")]
        let check = GitHubPullRequestCheck(name: "CI", state: "STALE", link: nil)

        #expect(PullRequestChecksStatus(checks: rollup) == .pending)
        #expect(check.presentationState == .pending)
    }

    @Test func incompleteOrMissingConclusionIsPending() {
        let incomplete = [GitHubPullRequestRollupCheck(status: "IN_PROGRESS", conclusion: nil)]
        let missingConclusion = [GitHubPullRequestRollupCheck(status: "COMPLETED", conclusion: nil)]
        #expect(PullRequestChecksStatus(checks: incomplete) == .pending)
        #expect(PullRequestChecksStatus(checks: missingConclusion) == .pending)
    }

    @Test func successWinsOnlyAfterFailureAndPendingAreAbsent() {
        let checks = [
            GitHubPullRequestRollupCheck(status: "COMPLETED", conclusion: "NEUTRAL"),
            GitHubPullRequestRollupCheck(status: "COMPLETED", conclusion: "SUCCESS"),
        ]
        #expect(PullRequestChecksStatus(checks: checks) == .success)
    }

    @Test func completedNeutralChecksProduceNeutralRollup() {
        let checks = [GitHubPullRequestRollupCheck(status: "COMPLETED", conclusion: "NEUTRAL")]
        #expect(PullRequestChecksStatus(checks: checks) == .neutral)
    }

    @Test func statusContextStateParticipatesInRollup() {
        let checks = [GitHubPullRequestRollupCheck(status: nil, conclusion: nil, state: "FAILURE")]
        #expect(PullRequestChecksStatus(checks: checks) == .failure)

        let expected = [GitHubPullRequestRollupCheck(status: nil, conclusion: nil, state: "EXPECTED")]
        #expect(PullRequestChecksStatus(checks: expected) == .pending)
    }
}
