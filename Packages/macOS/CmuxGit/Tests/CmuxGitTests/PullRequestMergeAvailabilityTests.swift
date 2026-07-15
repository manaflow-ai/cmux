import Testing
@testable import CmuxGit

@Suite struct PullRequestMergeAvailabilityTests {
    @Test(arguments: ["UNSTABLE", "HAS_HOOKS"])
    func optionalCheckAndHookStatesRemainMergeable(_ state: String) throws {
        let pullRequest = try PullRequestFixtureLoader().pullRequest(mergeStateStatus: state)
        #expect(PullRequestMergeAvailability.derive(pullRequest: pullRequest) == .allowed)
    }

    @Test func githubBlockedStateBlocksMerge() throws {
        let pullRequest = try PullRequestFixtureLoader().pullRequest(mergeStateStatus: "BLOCKED")
        #expect(
            PullRequestMergeAvailability.derive(pullRequest: pullRequest)
                == .blocked(.githubBlocked)
        )
    }

    @Test func behindStateRemainsDirectlyMergeable() throws {
        let pullRequest = try PullRequestFixtureLoader().pullRequest(mergeStateStatus: "BEHIND")
        #expect(PullRequestMergeAvailability.derive(pullRequest: pullRequest) == .allowed)
    }

    @Test func unknownPullRequestStateBlocksMerge() throws {
        let pullRequest = try PullRequestFixtureLoader().pullRequest(state: "FUTURE_STATE")
        #expect(
            PullRequestMergeAvailability.derive(pullRequest: pullRequest)
                == .blocked(.githubBlocked)
        )
    }

    @Test func unknownMergeableValueBlocksMerge() throws {
        let pullRequest = try PullRequestFixtureLoader().pullRequest(mergeable: "FUTURE_STATE")
        #expect(
            PullRequestMergeAvailability.derive(pullRequest: pullRequest)
                == .blocked(.githubBlocked)
        )
    }

    @Test func unknownMergeStateStatusBlocksMerge() throws {
        let pullRequest = try PullRequestFixtureLoader().pullRequest(mergeStateStatus: "FUTURE_STATE")
        #expect(
            PullRequestMergeAvailability.derive(pullRequest: pullRequest)
                == .blocked(.githubBlocked)
        )
    }

    @Test func unknownReviewDecisionBlocksMerge() throws {
        let pullRequest = try PullRequestFixtureLoader().pullRequest(reviewDecision: "FUTURE_STATE")
        #expect(
            PullRequestMergeAvailability.derive(pullRequest: pullRequest)
                == .blocked(.githubBlocked)
        )
    }

    @Test func emptyReviewDecisionRemainsMergeable() throws {
        let pullRequest = try PullRequestFixtureLoader().pullRequest(reviewDecision: "")
        #expect(PullRequestMergeAvailability.derive(pullRequest: pullRequest) == .allowed)
    }

    @Test func optionalCheckFailureDoesNotOverrideCleanGitHubState() throws {
        let snapshot = PullRequestPanelSnapshot(
            context: PullRequestPanelContext(
                repositoryRoot: "/repo",
                branch: "feature",
                repositorySlug: "example/repo"
            ),
            pullRequest: try PullRequestFixtureLoader().pullRequest(),
            checks: [],
            checksStatus: .failure,
            unresolvedReviewThreadCount: nil,
            mergeMethods: [.squash]
        )
        #expect(snapshot.mergeAvailability == .allowed)
    }
}
