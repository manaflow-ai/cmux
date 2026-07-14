import CmuxFoundation
import Foundation

extension GitHubPullRequestPanelService {
    /// Merges immediately or enables auto-merge using the selected method.
    public func merge(
        number: Int,
        context: PullRequestPanelContext,
        headRefOid: String,
        method: PullRequestMergeMethod,
        whenReady: Bool
    ) async throws {
        var arguments = ["pr", "merge", String(number)]
        if whenReady { arguments.append("--auto") }
        arguments.append(method.commandFlag)
        arguments.append(contentsOf: [
            "--repo", context.repositorySlug,
            "--match-head-commit", headRefOid,
        ])
        let result = await commandRunner.run(
            directory: context.repositoryRoot,
            executable: "gh",
            arguments: arguments,
            timeout: 30
        )
        _ = try requiredOutput(from: result, failure: .mergeFailed, allowsEmptyOutput: true)
    }

    /// Disables auto-merge for a pull request.
    public func disableAutoMerge(
        number: Int,
        context: PullRequestPanelContext,
        headRefOid: String
    ) async throws {
        let result = await commandRunner.run(
            directory: context.repositoryRoot,
            executable: "gh",
            arguments: [
                "pr", "merge", String(number), "--disable-auto",
                "--repo", context.repositorySlug,
                "--match-head-commit", headRefOid,
            ],
            timeout: 30
        )
        _ = try requiredOutput(from: result, failure: .mergeFailed, allowsEmptyOutput: true)
    }

    /// Opens GitHub's web-based pull-request creation flow.
    public func createPullRequest(context: PullRequestPanelContext) async throws {
        let result = await commandRunner.run(
            directory: context.repositoryRoot,
            executable: "gh",
            arguments: [
                "pr", "create", "--web",
                "--repo", context.repositorySlug,
            ],
            timeout: 30
        )
        _ = try requiredOutput(from: result, failure: .createFailed, allowsEmptyOutput: true)
    }
}
