import Testing
@testable import CmuxGit

@Suite struct PullRequestMergeAvailabilityTests {
    @Test(arguments: ["UNSTABLE", "HAS_HOOKS"])
    func optionalCheckAndHookStatesRemainMergeable(_ state: String) throws {
        let pullRequest = try pullRequestFixture(mergeStateStatus: state)
        #expect(PullRequestMergeAvailability.derive(pullRequest: pullRequest) == .allowed)
    }

    @Test func githubBlockedStateBlocksMerge() throws {
        let pullRequest = try pullRequestFixture(mergeStateStatus: "BLOCKED")
        #expect(
            PullRequestMergeAvailability.derive(pullRequest: pullRequest)
                == .blocked(.githubBlocked)
        )
    }

    @Test func optionalCheckFailureDoesNotOverrideCleanGitHubState() throws {
        let snapshot = PullRequestPanelSnapshot(
            context: PullRequestPanelContext(
                repositoryRoot: "/repo",
                branch: "feature",
                repositorySlug: "example/repo"
            ),
            pullRequest: try pullRequestFixture(),
            checks: [],
            checksStatus: .failure,
            unresolvedReviewThreadCount: nil,
            mergeMethods: [.squash]
        )
        #expect(snapshot.mergeAvailability == .allowed)
    }
}
