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

    private func detailStub(sha: String = "abc123", conflict: Bool = false) -> GitHubPullRequestStub {
        .init(statusCode: 200, data: Data("""
        {"mergeable":\(!conflict),"mergeable_state":"\(conflict ? "dirty" : "clean")","head":{"sha":"\(sha)"}}
        """.utf8))
    }

    /// Both payloads share a stub body so the two concurrent requests can
    /// arrive in either order without depending on scheduling.
    private func checksStub(conclusion: String = "success", state: String = "success", count: Int = 1) -> GitHubPullRequestStub {
        .init(statusCode: 200, data: Data("""
        {"total_count":\(count),
         "check_runs":[{"id":1,"name":"unit","status":"completed","conclusion":"\(conclusion)"}],
         "statuses":[{"id":2,"context":"deploy","state":"\(state)"}]}
        """.utf8))
    }

    @Test func optionalChecksIncludesLegacyStatusesAndMergeConflicts() async throws {
        PullRequestProbeStubURLProtocol.reset(stubs: [
            detailStub(conflict: true), checksStub(state: "pending"), checksStub(state: "pending"),
        ])
        let summary = try #require(await makeService().fetchPullRequestChecks(
            repoSlug: repoSlug, pullRequestNumber: 8175, headSHA: "abc123"
        ))
        #expect(summary.status == .pending)
        #expect(summary.mergeStatus == .conflict)
        #expect(summary.checks.map(\.name) == ["deploy", "unit"])
        #expect(summary.checks.map(\.status) == [.pending, .success])
    }

    @Test func checksCacheSeparatesPullRequestsAndCommitHeads() async throws {
        PullRequestProbeStubURLProtocol.reset(stubs: [
            detailStub(), checksStub(), checksStub(),
            detailStub(), checksStub(conclusion: "failure"), checksStub(conclusion: "failure"),
            detailStub(sha: "def456"), checksStub(state: "pending"), checksStub(state: "pending"),
        ])
        let service = makeService()
        let first = await service.fetchPullRequestChecks(repoSlug: repoSlug, pullRequestNumber: 1, headSHA: "abc123")
        let cached = await service.fetchPullRequestChecks(repoSlug: repoSlug, pullRequestNumber: 1, headSHA: "abc123")
        #expect(first?.status == .success)
        #expect(cached == first)
        #expect(requestURLStrings().count == 3)
        let second = await service.fetchPullRequestChecks(repoSlug: repoSlug, pullRequestNumber: 2, headSHA: "abc123")
        #expect(second?.status == .failure)
        let pushed = await service.fetchPullRequestChecks(repoSlug: repoSlug, pullRequestNumber: 1, headSHA: "def456")
        #expect(pushed?.status == .pending)
        #expect(requestURLStrings().contains { $0.contains("/commits/def456/") })
        #expect(requestURLStrings().count == 9)
    }

    @Test func failedEndpointsNeverBecomePassingOrNoChecks() async throws {
        PullRequestProbeStubURLProtocol.reset(stubs: [
            detailStub(), .init(statusCode: 403), .init(statusCode: 403),
        ])
        let summary = await makeService().fetchPullRequestChecks(repoSlug: repoSlug, pullRequestNumber: 1, headSHA: "abc123")
        #expect(summary?.status == .unavailable)
        #expect(summary?.mergeStatus == .ready)
    }

    @Test func emptySuccessfulEndpointsAreNeutral() async throws {
        let empty = GitHubPullRequestStub(statusCode: 200, data: Data("""
        {"total_count":0,"check_runs":[],"statuses":[]}
        """.utf8))
        PullRequestProbeStubURLProtocol.reset(stubs: [detailStub(), empty, empty])
        let summary = await makeService().fetchPullRequestChecks(repoSlug: repoSlug, pullRequestNumber: 1, headSHA: "abc123")
        #expect(summary?.status == .neutral)
        #expect(summary?.checks.isEmpty == true)
    }

    @Test func checkRunFailureOnLaterPagePreventsFalseGreen() async throws {
        PullRequestProbeStubURLProtocol.reset(stubs: [
            checksStub(count: 101),
            .init(statusCode: 200, data: Data("""
            {"total_count":101,"check_runs":[{"id":101,"name":"integration","status":"completed","conclusion":"failure"}]}
            """.utf8)),
        ])
        let runs = await makeService().fetchCheckRuns(repoSlug: repoSlug, sha: "abc123", authHeader: "Bearer fixture")
        #expect(runs.complete)
        #expect(PullRequestProbeService.overallCheckStatus(runs.checks) == .failure)
        #expect(requestURLStrings().last?.contains("page=2") == true)
    }

    @Test func commitPushDuringLookupUsesNewerDetailHead() async throws {
        PullRequestProbeStubURLProtocol.reset(stubs: [detailStub(sha: "def456"), checksStub(), checksStub()])
        let summary = await makeService().fetchPullRequestChecks(repoSlug: repoSlug, pullRequestNumber: 1, headSHA: "abc123")
        #expect(summary?.status == .success)
        let urls = requestURLStrings()
        #expect(urls.filter { $0.contains("/commits/def456/") }.count == 2)
        #expect(!urls.contains { $0.contains("/commits/abc123/") })
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
