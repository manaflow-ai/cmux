import Foundation
import Testing
@testable import CmuxGit
import CmuxFoundation

/// Network fetch-layer behavior for ``PullRequestProbeService``. These drive the
/// service's ``fetchRepoResults(...)`` through a stub `URLSession`, proving the
/// per-branch `head=` resolution keeps GitHub's conditional (ETag/304) cache
/// effective — the fix for the poller that re-fetched `state=all&sort=updated`
/// pages and defeated its own cache (manaflow-ai/cmux#8367).
@Suite(.serialized)
struct PullRequestProbeServiceFetchTests {
    private let repoSlug = "manaflow-ai/cmux"

    private func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PullRequestProbeStubURLProtocol.self]
        configuration.timeoutIntervalForRequest = 2
        configuration.timeoutIntervalForResource = 2
        return URLSession(configuration: configuration)
    }

    private func makeService() -> PullRequestProbeService {
        PullRequestProbeService(
            commandRunner: FixedTokenCommandRunner(),
            requestCoordinator: GitHubPullRequestRequestCoordinator(session: makeSession())
        )
    }

    private func pullRequestJSON(
        number: Int,
        branch: String,
        state: String = "open",
        mergedAt: String? = nil
    ) -> String {
        let mergedField = mergedAt.map { "\"\($0)\"" } ?? "null"
        return """
        {
          "number": \(number),
          "state": "\(state)",
          "html_url": "https://github.com/\(repoSlug)/pull/\(number)",
          "updated_at": "2026-07-01T12:00:00Z",
          "merged_at": \(mergedField),
          "head": {"ref": "\(branch)"},
          "base": {"ref": "main"}
        }
        """
    }

    private func listBody(_ items: String...) -> Data {
        Data("[\(items.joined(separator: ","))]".utf8)
    }

    private func fetch(
        service: PullRequestProbeService,
        branches: Set<String>,
        cache: [String: WorkspacePullRequestRepoCacheEntry] = [:],
        now: Date = Date(),
        allowCachedResults: Bool = false
    ) async -> WorkspacePullRequestRepoFetchResult {
        let (repoResults, _) = await service.fetchRepoResults(
            repoDirectoriesBySlug: [repoSlug: "/tmp/\(repoSlug)"],
            candidateBranchesByRepo: [repoSlug: branches],
            cacheBySlug: cache,
            now: now,
            allowCachedResults: allowCachedResults
        )
        return repoResults[repoSlug] ?? .transientFailure
    }

    private func entry(
        from result: WorkspacePullRequestRepoFetchResult
    ) -> WorkspacePullRequestRepoCacheEntry? {
        guard case .success(let entry, _, _) = result else { return nil }
        return entry
    }

    private func requestURLStrings() -> [String] {
        PullRequestProbeStubURLProtocol.capturedRequests().map { $0.url?.absoluteString ?? "" }
    }

    private func hasQueryItem(named name: String, in urlString: String) -> Bool {
        URLComponents(string: urlString)?.queryItems?.contains { $0.name == name } == true
    }

    @Test func coldFetchIssuesPerBranchHeadRequestsAndNoListPagination() async throws {
        PullRequestProbeStubURLProtocol.reset(stubs: [
            .init(statusCode: 200, data: listBody(pullRequestJSON(number: 8175, branch: "feat/badge"))),
        ])
        let service = makeService()

        let result = await fetch(service: service, branches: ["feat/badge"])

        let resolved = try #require(entry(from: result))
        #expect(resolved.pullRequestsByBranch["feat/badge"]?.number == 8175)
        let urls = requestURLStrings()
        #expect(urls.count == 1)
        #expect(urls.allSatisfy { $0.contains("head=") })
        // The defeated-cache pagination path (?state=all&sort=updated&…&page=N)
        // must be gone — no listing request should be issued.
        #expect(urls.allSatisfy { !hasQueryItem(named: "page", in: $0) })
    }

    @Test func secondRefreshRevalidatesUnchangedBranchTo304() async throws {
        let body = listBody(pullRequestJSON(number: 8175, branch: "feat/badge"))
        PullRequestProbeStubURLProtocol.reset(stubs: [
            .init(statusCode: 200, headers: ["ETag": "\"badge-8175\""], data: body),
            .init(statusCode: 304),
        ])
        let service = makeService()

        let first = await fetch(service: service, branches: ["feat/badge"])
        let second = await fetch(service: service, branches: ["feat/badge"])

        #expect(entry(from: first)?.pullRequestsByBranch["feat/badge"]?.number == 8175)
        // The 304 short-circuits to the cached body: the badge still resolves.
        #expect(entry(from: second)?.pullRequestsByBranch["feat/badge"]?.number == 8175)
        let requests = PullRequestProbeStubURLProtocol.capturedRequests()
        #expect(requests.count == 2)
        #expect(try #require(requests.last).value(forHTTPHeaderField: "If-None-Match") == "\"badge-8175\"")
    }

    @Test func notFoundBranchBecomesKnownAbsentAndIsNotRefetchedFromFreshCache() async throws {
        PullRequestProbeStubURLProtocol.reset(stubs: [
            .init(statusCode: 404, data: Data("{\"message\":\"Not Found\"}".utf8)),
        ])
        let service = makeService()

        let coldResult = await fetch(service: service, branches: ["deleted/branch"])
        let coldEntry = try #require(entry(from: coldResult))
        #expect(coldEntry.knownAbsentBranches.contains("deleted/branch"))
        #expect(coldEntry.pullRequestsByBranch["deleted/branch"] == nil)
        #expect(PullRequestProbeStubURLProtocol.capturedRequests().count == 1)

        // A fresh cache that already marks the branch absent must not re-poll it,
        // so a renamed/deleted repo backs off the fast loop instead of 404ing forever.
        let cachedResult = await fetch(
            service: service,
            branches: ["deleted/branch"],
            cache: [repoSlug: coldEntry],
            now: coldEntry.fetchedAt,
            allowCachedResults: true
        )
        guard case .success(_, let usedCache, _) = cachedResult else {
            Issue.record("expected cached success, got \(cachedResult)")
            return
        }
        #expect(usedCache)
        #expect(PullRequestProbeStubURLProtocol.capturedRequests().count == 1)
    }

    @Test func multipleCandidateBranchesEachGetOwnHeadRequest() async throws {
        // Each response carries both PRs; the per-branch `head=` filter keeps
        // only the matching one, so resolution is order-independent under the
        // concurrent task group.
        let combined = listBody(
            pullRequestJSON(number: 8100, branch: "feat/alpha"),
            pullRequestJSON(number: 8200, branch: "feat/beta")
        )
        PullRequestProbeStubURLProtocol.reset(stubs: [
            .init(statusCode: 200, data: combined),
            .init(statusCode: 200, data: combined),
        ])
        let service = makeService()

        let result = await fetch(service: service, branches: ["feat/alpha", "feat/beta"])

        let resolved = try #require(entry(from: result))
        #expect(resolved.pullRequestsByBranch["feat/alpha"]?.number == 8100)
        #expect(resolved.pullRequestsByBranch["feat/beta"]?.number == 8200)
        let urls = requestURLStrings()
        #expect(urls.count == 2)
        #expect(urls.contains { $0.contains("feat/alpha") || $0.contains("feat%2Falpha") })
        #expect(urls.contains { $0.contains("feat/beta") || $0.contains("feat%2Fbeta") })
        #expect(urls.allSatisfy { !hasQueryItem(named: "page", in: $0) })
    }

    private func checkNode(
        id: String = "run1", name: String = "unit", conclusion: String = "SUCCESS",
        started: String = "2026-09-16T00:00:00Z", workflow: String = "workflow1"
    ) -> [String: Any] {
        ["__typename": "CheckRun", "id": id, "name": name, "status": "COMPLETED", "conclusion": conclusion,
         "startedAt": started, "checkSuite": ["app": ["id": "app1"], "workflowRun": ["event": "pull_request", "workflow": ["id": workflow]]]]
    }

    private func checksStub(
        sha: String = "abc123", conflict: Bool = false, nodes: [[String: Any]], cursor: String? = nil
    ) throws -> GitHubPullRequestStub {
        let contexts: [String: Any] = [
            "nodes": nodes, "pageInfo": ["hasNextPage": cursor != nil, "endCursor": cursor as Any? ?? NSNull()]
        ]
        let commit: [String: Any] = ["oid": sha, "statusCheckRollup": ["contexts": contexts]]
        let pr: [String: Any] = [
            "mergeable": conflict ? "CONFLICTING" : "MERGEABLE", "mergeStateStatus": conflict ? "DIRTY" : "CLEAN",
            "commits": ["nodes": [["commit": commit]]]
        ]
        return .init(statusCode: 200, data: try JSONSerialization.data(withJSONObject: ["data": ["repository": ["pullRequest": pr]]]))
    }

    @Test func optionalChecksIncludesLegacyStatusesAndMergeConflicts() async throws {
        let legacy: [String: Any] = ["__typename": "StatusContext", "id": "status1", "context": "deploy", "state": "PENDING"]
        PullRequestProbeStubURLProtocol.reset(stubs: [try checksStub(conflict: true, nodes: [checkNode(), legacy])])
        let summary = try #require(await makeService().fetchPullRequestChecks(repoSlug: repoSlug, pullRequestNumber: 8175, headSHA: "abc123"))
        #expect(summary.status == .pending)
        #expect(summary.mergeStatus == .conflict)
        #expect(summary.checks.map(\.name) == ["deploy", "unit"])
        #expect(summary.checks.map(\.status) == [.pending, .success])
        let request = try #require(PullRequestProbeStubURLProtocol.capturedRequests().first)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.path == "/graphql")
    }

    @Test func checksCacheSeparatesPullRequestsAndCommitHeads() async throws {
        PullRequestProbeStubURLProtocol.reset(stubs: [
            try checksStub(nodes: [checkNode()]),
            try checksStub(nodes: [checkNode(conclusion: "FAILURE")]),
            try checksStub(sha: "def456", nodes: []),
        ])
        let service = makeService()
        let first = await service.fetchPullRequestChecks(repoSlug: repoSlug, pullRequestNumber: 1, headSHA: "abc123")
        let cached = await service.fetchPullRequestChecks(repoSlug: repoSlug, pullRequestNumber: 1, headSHA: "abc123")
        #expect(first?.status == .success)
        #expect(cached == first)
        #expect(requestURLStrings().count == 1)
        let second = await service.fetchPullRequestChecks(repoSlug: repoSlug, pullRequestNumber: 2, headSHA: "abc123")
        #expect(second?.status == .failure)
        let pushed = await service.fetchPullRequestChecks(repoSlug: repoSlug, pullRequestNumber: 1, headSHA: "def456")
        #expect(pushed?.status == .neutral)
        #expect(requestURLStrings().count == 3)
    }

    @Test func failedEndpointsNeverBecomePassingOrNoChecks() async throws {
        PullRequestProbeStubURLProtocol.reset(stubs: [.init(statusCode: 403)])
        let summary = await makeService().fetchPullRequestChecks(repoSlug: repoSlug, pullRequestNumber: 1, headSHA: "abc123")
        #expect(summary?.status == .unavailable)
        #expect(summary?.mergeStatus == .unknown)
    }

    @Test func emptySuccessfulRollupIsNeutral() async throws {
        PullRequestProbeStubURLProtocol.reset(stubs: [try checksStub(nodes: [])])
        let summary = await makeService().fetchPullRequestChecks(repoSlug: repoSlug, pullRequestNumber: 1, headSHA: "abc123")
        #expect(summary?.status == .neutral)
        #expect(summary?.checks.isEmpty == true)
    }

    @Test func failureOnLaterPagePreventsFalseGreen() async throws {
        PullRequestProbeStubURLProtocol.reset(stubs: [
            try checksStub(nodes: [checkNode()], cursor: "next"),
            try checksStub(nodes: [checkNode(id: "run2", name: "integration", conclusion: "FAILURE")])
        ])
        let summary = await makeService().fetchPullRequestChecks(repoSlug: repoSlug, pullRequestNumber: 1, headSHA: "abc123")
        #expect(summary?.status == .failure)
        #expect(summary?.checks.count == 2)
        #expect(requestURLStrings().count == 2)
    }

    @Test func rerunsReplaceOldAttemptsWithoutCollapsingOtherWorkflows() async throws {
        let old = checkNode(id: "old", conclusion: "FAILURE")
        let new = checkNode(id: "new", started: "2026-09-16T01:00:00Z")
        let separate = checkNode(id: "other", workflow: "workflow2")
        PullRequestProbeStubURLProtocol.reset(stubs: [try checksStub(nodes: [new, old, separate])])
        let summary = await makeService().fetchPullRequestChecks(repoSlug: repoSlug, pullRequestNumber: 1, headSHA: "abc123")
        #expect(summary?.status == .success)
        #expect(Set(summary?.checks.map(\.id) ?? []) == ["new", "other"])
    }

    @Test func queuedRerunSupersedesOlderPassingAttemptBeforeItStarts() async throws {
        var old = checkNode(id: "old")
        old["databaseId"] = 1
        var queued = checkNode(id: "queued")
        queued["databaseId"] = 2
        queued["status"] = "QUEUED"
        queued["conclusion"] = NSNull()
        queued["startedAt"] = NSNull()
        PullRequestProbeStubURLProtocol.reset(stubs: [try checksStub(nodes: [queued, old])])
        let summary = await makeService().fetchPullRequestChecks(repoSlug: repoSlug, pullRequestNumber: 1, headSHA: "abc123")
        #expect(summary?.status == .pending)
        #expect(summary?.checks.map(\.id) == ["queued"])
    }

    @Test func pushBetweenPagesDiscardsMixedCommitResults() async throws {
        PullRequestProbeStubURLProtocol.reset(stubs: [
            try checksStub(nodes: [checkNode()], cursor: "next"),
            try checksStub(sha: "def456", nodes: [])
        ])
        let summary = await makeService().fetchPullRequestChecks(repoSlug: repoSlug, pullRequestNumber: 1, headSHA: "abc123")
        #expect(summary == nil)
    }

    @Test func missingOrMismatchedHeadNeverPublishesChecks() async throws {
        let service = makeService()
        PullRequestProbeStubURLProtocol.reset(stubs: [])
        #expect(await service.fetchPullRequestChecks(repoSlug: repoSlug, pullRequestNumber: 1, headSHA: nil) == nil)
        #expect(await service.fetchPullRequestChecks(repoSlug: repoSlug, pullRequestNumber: 1, headSHA: "") == nil)
        #expect(requestURLStrings().isEmpty)
        PullRequestProbeStubURLProtocol.reset(stubs: [try checksStub(sha: "def456", nodes: [checkNode()])])
        #expect(await service.fetchPullRequestChecks(repoSlug: repoSlug, pullRequestNumber: 1, headSHA: "abc123") == nil)
    }

    @Test func invalidatedProjectionCannotRestoreCachedPassingChecks() async throws {
        PullRequestProbeStubURLProtocol.reset(stubs: [
            try checksStub(nodes: [checkNode()]),
            try checksStub(sha: "def456", nodes: [])
        ])
        let service = makeService()
        let initial = await service.fetchPullRequestChecks(repoSlug: repoSlug, pullRequestNumber: 1, headSHA: "abc123")
        #expect(initial?.status == .success)
        let invalidated = await service.fetchPullRequestChecks(
            repoSlug: repoSlug, pullRequestNumber: 1, headSHA: "abc123", allowCachedResults: false
        )
        #expect(invalidated == nil)
        #expect(requestURLStrings().count == 2)
    }

    @Test func partialGraphQLErrorsCannotBecomeSuccess() async throws {
        PullRequestProbeStubURLProtocol.reset(stubs: [.init(statusCode: 200, data: Data("{\"errors\":[{\"message\":\"unavailable\"}]}".utf8))])
        let summary = await makeService().fetchPullRequestChecks(repoSlug: repoSlug, pullRequestNumber: 1, headSHA: "abc123")
        #expect(summary?.status == .unavailable)
    }

}

/// Resolves a stable non-empty auth header so the fetch layer proceeds without a
/// live `gh auth token` (or environment token).
private actor FixedTokenCommandRunner: CommandRunning {
    func run(
        directory: String,
        executable: String,
        arguments: [String],
        timeout: TimeInterval?
    ) async -> CommandResult {
        CommandResult(
            stdout: "ghtok-fixture",
            stderr: nil,
            exitStatus: 0,
            timedOut: false,
            executionError: nil
        )
    }
}
