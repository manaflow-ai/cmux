import Testing
@testable import CmuxGit

@Suite struct PullRequestMergeMethodTests {
    @Test func repositoryDefaultIsOrderedFirst() {
        let settings = GitHubRepositoryMergeSettings(
            mergeCommitAllowed: true,
            rebaseMergeAllowed: true,
            squashMergeAllowed: true,
            viewerDefaultMergeMethod: .rebase
        )
        #expect(settings.orderedMergeMethods == [.rebase, .squash, .merge])
    }

    @Test func squashIsFallbackDefault() {
        let settings = GitHubRepositoryMergeSettings(
            mergeCommitAllowed: true,
            rebaseMergeAllowed: true,
            squashMergeAllowed: true
        )
        #expect(settings.orderedMergeMethods == [.squash, .merge, .rebase])
    }

    @Test func disallowedMethodsAreRemovedAndFirstAllowedBecomesDefault() {
        let settings = GitHubRepositoryMergeSettings(
            mergeCommitAllowed: false,
            rebaseMergeAllowed: true,
            squashMergeAllowed: false,
            viewerDefaultMergeMethod: .merge
        )
        #expect(settings.orderedMergeMethods == [.rebase])
    }

    @Test func malformedEmptyPolicyFallsBackToSquash() {
        let settings = GitHubRepositoryMergeSettings(
            mergeCommitAllowed: false,
            rebaseMergeAllowed: false,
            squashMergeAllowed: false
        )
        #expect(settings.orderedMergeMethods == [.squash])
    }
}
