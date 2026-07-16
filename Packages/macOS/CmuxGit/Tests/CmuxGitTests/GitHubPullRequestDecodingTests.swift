import Foundation
import Testing
@testable import CmuxGit

@Suite struct GitHubPullRequestDecodingTests {
    @Test func decodesCapturedGitHubCLIPayloads() throws {
        let loader = PullRequestFixtureLoader()
        let pullRequest = try loader.decode(GitHubPullRequest.self, named: "pull-request-view")
        let checks = try loader.decode([GitHubPullRequestCheck].self, named: "pull-request-checks")
        let settings = try loader.decode(GitHubRepositoryMergeSettings.self, named: "repository-merge-settings")

        #expect(pullRequest.number == 7952)
        #expect(pullRequest.title == "Stabilize sidebar ports across transient scan misses")
        #expect(pullRequest.url.absoluteString == "https://github.com/manaflow-ai/cmux/pull/7952")
        #expect(pullRequest.statusCheckRollup.count == 3)
        #expect(pullRequest.statusCheckRollup.last?.state == "SUCCESS")
        #expect(pullRequest.isAutoMergeEnabled)
        #expect(pullRequest.baseRefName == "main")
        #expect(pullRequest.headRefName == "feat-pr-sidebar")
        #expect(checks.map(\.presentationState) == [.success, .pending])
        #expect(settings.squashMergeAllowed)
        #expect(settings.mergeCommitAllowed)
        #expect(settings.rebaseMergeAllowed)
        #expect(settings.viewerDefaultMergeMethod == .squash)
    }
}
