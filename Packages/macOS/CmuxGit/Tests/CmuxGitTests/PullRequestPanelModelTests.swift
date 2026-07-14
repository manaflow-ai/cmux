import Testing
@testable import CmuxGit

@Suite struct PullRequestPanelModelTests {
    @Test @MainActor func refreshFailurePreservesCachedContent() async {
        let input = PullRequestWorkspaceInput(directory: "/repo", branchHint: "feature")
        let context = PullRequestPanelContext(
            repositoryRoot: "/repo",
            branch: "feature",
            repositorySlug: "example/repo"
        )
        let cached = PullRequestPanelContent.noPullRequest(context)
        let service = StubPullRequestPanelService(
            cached: cached,
            refreshResult: .failure(.refreshFailed)
        )
        let model = PullRequestPanelModel(service: service)

        model.setVisible(true)
        await model.activate(input)

        #expect(model.phase == .failed(cached: cached, error: .refreshFailed))
        #expect(model.phase.displayedContent == cached)
        model.setVisible(false)
    }
}
