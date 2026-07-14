import Testing
@testable import CmuxGit

@Suite struct PullRequestMergeMethodTests {
    @Test func repositoryDefaultIsOrderedFirst() {
        let settings = GitHubRepositoryMergeSettings(
            mergeCommitAllowed: true,
            rebaseMergeAllowed: true,
            squashMergeAllowed: true
        )
        #expect(
            PullRequestMergeMethod.orderedAllowed(settings: settings, defaultMethod: .rebase)
                == [.rebase, .squash, .merge]
        )
    }

    @Test func squashIsFallbackDefault() {
        let settings = GitHubRepositoryMergeSettings(
            mergeCommitAllowed: true,
            rebaseMergeAllowed: true,
            squashMergeAllowed: true
        )
        #expect(
            PullRequestMergeMethod.orderedAllowed(settings: settings, defaultMethod: nil)
                == [.squash, .merge, .rebase]
        )
    }

    @Test func disallowedMethodsAreRemovedAndFirstAllowedBecomesDefault() {
        let settings = GitHubRepositoryMergeSettings(
            mergeCommitAllowed: false,
            rebaseMergeAllowed: true,
            squashMergeAllowed: false
        )
        #expect(
            PullRequestMergeMethod.orderedAllowed(settings: settings, defaultMethod: .merge)
                == [.rebase]
        )
    }

    @Test func malformedEmptyPolicyFallsBackToSquash() {
        let settings = GitHubRepositoryMergeSettings(
            mergeCommitAllowed: false,
            rebaseMergeAllowed: false,
            squashMergeAllowed: false
        )
        #expect(
            PullRequestMergeMethod.orderedAllowed(settings: settings, defaultMethod: nil)
                == [.squash]
        )
    }
}
