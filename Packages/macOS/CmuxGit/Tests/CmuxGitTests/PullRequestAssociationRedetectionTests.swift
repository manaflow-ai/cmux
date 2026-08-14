import Foundation
import Testing
@testable import CmuxGit
import CmuxFoundation

@Suite struct PullRequestAssociationRedetectionTests {
    private func item(
        number: Int,
        state: String,
        branch: String,
        mergedAt: String? = nil
    ) -> GitHubPullRequestProbeItem {
        GitHubPullRequestProbeItem(
            number: number,
            state: state,
            url: "https://github.com/manaflow-ai/cmux/pull/\(number)",
            updatedAt: "2026-07-01T12:00:00Z",
            mergedAt: mergedAt,
            headRefName: branch,
            baseRefName: "main"
        )
    }

    private func writeGitHubRemoteConfig(_ fixture: GitRepositoryFixture) throws {
        try fixture.writeConfig("""
        [remote "origin"]
            url = git@github.com:manaflow-ai/cmux.git
        """)
    }

    @Test func staleProjectedBranchReresolvesToOpenPullRequestForCurrentBranch() async throws {
        let oldBranch = "issue-7728-safari-default-browser-signin"
        let newBranch = "issue-7728-safari-signin-followup"
        let fixture = try GitRepositoryFixture()
        try fixture.writeBranch(newBranch)
        try writeGitHubRemoteConfig(fixture)
        let workspaceId = UUID()
        let panelId = UUID()
        let seed = WorkspacePullRequestCandidateSeed(
            workspaceId: workspaceId,
            panelId: panelId,
            branch: oldBranch,
            directory: fixture.root.path
        )
        let service = PullRequestProbeService(commandRunner: CountingCommandRunner(outputs: []))

        let resolution = await service.resolveCandidateSeeds(
            [seed],
            gitMetadata: GitMetadataService()
        )
        let entry = WorkspacePullRequestRepoCacheEntry(
            fetchedAt: Date(),
            pullRequestsByBranch: [
                oldBranch: item(
                    number: 7739,
                    state: "MERGED",
                    branch: oldBranch,
                    mergedAt: "2026-07-01T12:00:00Z"
                ),
                newBranch: item(number: 7776, state: "OPEN", branch: newBranch),
            ]
        )

        let results = PullRequestProbeService.resolveRefreshResults(
            candidates: resolution.candidates,
            repoResults: ["manaflow-ai/cmux": .success(entry, usedCache: false, transientBranches: [])]
        )
        let result = try #require(results.first)
        guard case .resolved(let resolved) = result.resolution else {
            Issue.record("expected resolved, got \(result.resolution)")
            return
        }
        #expect(resolved.number == 7776)
        #expect(resolved.statusRawValue == PullRequestStatus.open.rawValue)
        #expect(resolved.branch == newBranch)
    }

    @Test func detachedHeadFallsBackToProjectedBranch() async throws {
        let projectedBranch = "issue-7728-safari-default-browser-signin"
        let fixture = try GitRepositoryFixture()
        try fixture.writeDetachedHead(commit: String(repeating: "1", count: 40))
        try writeGitHubRemoteConfig(fixture)
        let workspaceId = UUID()
        let panelId = UUID()
        let seed = WorkspacePullRequestCandidateSeed(
            workspaceId: workspaceId,
            panelId: panelId,
            branch: projectedBranch,
            directory: fixture.root.path
        )
        let service = PullRequestProbeService(commandRunner: CountingCommandRunner(outputs: []))

        let resolution = await service.resolveCandidateSeeds(
            [seed],
            gitMetadata: GitMetadataService()
        )
        let entry = WorkspacePullRequestRepoCacheEntry(
            fetchedAt: Date(),
            pullRequestsByBranch: [
                projectedBranch: item(
                    number: 7739,
                    state: "MERGED",
                    branch: projectedBranch,
                    mergedAt: "2026-07-01T12:00:00Z"
                ),
            ]
        )

        let results = PullRequestProbeService.resolveRefreshResults(
            candidates: resolution.candidates,
            repoResults: ["manaflow-ai/cmux": .success(entry, usedCache: false, transientBranches: [])]
        )
        let result = try #require(results.first)
        guard case .resolved(let resolved) = result.resolution else {
            Issue.record("expected resolved, got \(result.resolution)")
            return
        }
        #expect(resolved.number == 7739)
        #expect(resolved.statusRawValue == PullRequestStatus.merged.rawValue)
        #expect(resolved.branch == projectedBranch)
    }

    /// A repository whose `HEAD` is missing/unreadable must not re-match the
    /// stale projected branch: the candidate resolves as a transient failure
    /// (existing badge kept, no lookup) until the branch can be verified.
    @Test func unreadableHeadResolvesTransientFailureWithoutLookup() async throws {
        let projectedBranch = "issue-7728-safari-default-browser-signin"
        let fixture = try GitRepositoryFixture()
        try writeGitHubRemoteConfig(fixture)
        let workspaceId = UUID()
        let panelId = UUID()
        let seed = WorkspacePullRequestCandidateSeed(
            workspaceId: workspaceId,
            panelId: panelId,
            branch: projectedBranch,
            directory: fixture.root.path
        )
        let service = PullRequestProbeService(commandRunner: CountingCommandRunner(outputs: []))

        let resolution = await service.resolveCandidateSeeds(
            [seed],
            gitMetadata: GitMetadataService()
        )

        #expect(resolution.candidateBranchesByRepo["manaflow-ai/cmux"] == nil)
        let entry = WorkspacePullRequestRepoCacheEntry(
            fetchedAt: Date(),
            pullRequestsByBranch: [
                projectedBranch: item(
                    number: 7739,
                    state: "MERGED",
                    branch: projectedBranch,
                    mergedAt: "2026-07-01T12:00:00Z"
                ),
            ]
        )
        let results = PullRequestProbeService.resolveRefreshResults(
            candidates: resolution.candidates,
            repoResults: ["manaflow-ai/cmux": .success(entry, usedCache: false, transientBranches: [])]
        )
        let result = try #require(results.first)
        guard case .transientFailure = result.resolution else {
            Issue.record("expected transientFailure, got \(result.resolution)")
            return
        }
    }

    @Test func detectedDefaultBranchResolvesNotFoundWithoutLookup() async throws {
        let fixture = try GitRepositoryFixture()
        try fixture.writeBranch("main")
        try writeGitHubRemoteConfig(fixture)
        let workspaceId = UUID()
        let panelId = UUID()
        let seed = WorkspacePullRequestCandidateSeed(
            workspaceId: workspaceId,
            panelId: panelId,
            branch: "feature/old",
            directory: fixture.root.path
        )
        let service = PullRequestProbeService(commandRunner: CountingCommandRunner(outputs: []))

        let resolution = await service.resolveCandidateSeeds(
            [seed],
            gitMetadata: GitMetadataService()
        )

        #expect(resolution.candidateBranchesByRepo["manaflow-ai/cmux"] == nil)
        #expect(resolution.repoDirectoriesBySlug["manaflow-ai/cmux"] == nil)
        let results = PullRequestProbeService.resolveRefreshResults(
            candidates: resolution.candidates,
            repoResults: [:]
        )
        let result = try #require(results.first)
        guard case .notFound = result.resolution else {
            Issue.record("expected notFound, got \(result.resolution)")
            return
        }
    }

    @Test func authHeaderValueReusesSuccessfulGitHubCliToken() async {
        let runner = CountingCommandRunner(outputs: ["token-one\n", "token-two\n"])
        let service = PullRequestProbeService(commandRunner: runner)

        let first = await service.authHeaderValue()
        let second = await service.authHeaderValue()

        if Self.hasEnvironmentToken {
            #expect(first == second)
            #expect(await runner.runCount == 0)
        } else {
            #expect(first == "Bearer token-one")
            #expect(second == "Bearer token-one")
            #expect(await runner.runCount == 1)
        }
    }

    @Test func authHeaderCacheDoesNotReuseNilForSuccessLifetime() async {
        let cache = GitHubAuthHeaderCache(successLifetime: 5 * 60, failureLifetime: 0)
        let counter = ResolutionCounter(outputs: [nil, "Bearer token-two"])

        let first = await cache.header {
            await counter.next()
        }
        let second = await cache.header {
            await counter.next()
        }

        #expect(first == nil)
        #expect(second == "Bearer token-two")
        #expect(await counter.count == 2)
    }

    private static var hasEnvironmentToken: Bool {
        let environment = ProcessInfo.processInfo.environment
        let token = environment["GH_TOKEN"] ?? environment["GITHUB_TOKEN"] ?? ""
        return !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

private actor CountingCommandRunner: CommandRunning {
    private var outputs: [String?]
    private(set) var runCount = 0

    init(outputs: [String?]) {
        self.outputs = outputs
    }

    func run(
        directory: String,
        executable: String,
        arguments: [String],
        timeout: TimeInterval?
    ) async -> CommandResult {
        runCount += 1
        let output = outputs.isEmpty ? nil : outputs.removeFirst()
        return CommandResult(
            stdout: output ?? "",
            stderr: nil,
            exitStatus: output == nil ? 1 : 0,
            timedOut: false,
            executionError: nil
        )
    }
}

private actor ResolutionCounter {
    private var outputs: [String?]
    private(set) var count = 0

    init(outputs: [String?]) {
        self.outputs = outputs
    }

    func next() -> String? {
        count += 1
        return outputs.isEmpty ? nil : outputs.removeFirst()
    }
}
