import Foundation
import Testing
@testable import CmuxGit

@Suite(.serialized) struct PullRequestProbeServiceCIStatusTests {
    private func item(
        number: Int,
        state: String,
        url: String = "https://github.com/manaflow-ai/cmux/pull/1",
        updatedAt: String?,
        ciStatus: PullRequestCIStatus = .neutral
    ) -> GitHubPullRequestProbeItem {
        GitHubPullRequestProbeItem(
            number: number,
            state: state,
            url: url,
            updatedAt: updatedAt,
            ciStatus: ciStatus
        )
    }

    @Test(arguments: [
        ("SUCCESS", PullRequestCIStatus.success),
        ("failure", .failure),
        ("ERROR", .failure),
        ("PENDING", .neutral),
        ("EXPECTED", .neutral),
        (nil, .neutral),
    ] as [(String?, PullRequestCIStatus)])
    func ciStatusMapsGitHubRollupStates(raw: String?, expected: PullRequestCIStatus) {
        #expect(PullRequestCIStatus(statusCheckRollupState: raw) == expected)
    }

    @Test func ciStatusFetchQueriesExactPullRequestNumbersAndDecodesRollups() async throws {
        let session = Self.mockSession()
        PullRequestCIMockURLProtocol.handler = { request in
            let body = String(
                decoding: PullRequestCIMockURLProtocol.bodyData(from: request),
                as: UTF8.self
            )
            #expect(body.contains("pullRequest(number: 1)"))
            #expect(body.contains("pullRequest(number: 2)"))
            #expect(body.contains("pullRequest(number: 3)"))
            #expect(!body.contains("pullRequests(states: OPEN"))
            return try Self.graphQLResponse(
                request: request,
                json: """
                {
                  "data": {
                    "repository": {
                      "pr0": {"number": 1, "commits": {"nodes": [{"commit": {"statusCheckRollup": {"state": "SUCCESS"}}}]}},
                      "pr1": {"number": 2, "commits": {"nodes": [{"commit": {"statusCheckRollup": {"state": "ERROR"}}}]}},
                      "pr2": {"number": 3, "commits": {"nodes": [{"commit": {"statusCheckRollup": null}}]}},
                      "pr3": null
                    }
                  },
                  "errors": [{"message": "partial but decodable"}]
                }
                """
            )
        }
        defer { PullRequestCIMockURLProtocol.handler = nil }

        let service = PullRequestProbeService()
        let statuses = await service.pullRequestCIStatusesByNumber(
            repoSlug: "manaflow-ai/cmux",
            pullRequestNumbers: [1, 2, 3],
            session: session,
            authHeader: "Bearer test-token"
        )
        #expect(statuses == [1: .success, 2: .failure, 3: .neutral])
    }

    @Test func ciStatusFetchTreatsAllErrorNoStatusResponseAsTransientFailure() async throws {
        let session = Self.mockSession()
        PullRequestCIMockURLProtocol.handler = { request in
            try Self.graphQLResponse(
                request: request,
                json: """
                {
                  "data": null,
                  "errors": [{"message": "rate limit exceeded"}]
                }
                """
            )
        }
        defer { PullRequestCIMockURLProtocol.handler = nil }

        let service = PullRequestProbeService()
        let statuses = await service.pullRequestCIStatusesByNumber(
            repoSlug: "manaflow-ai/cmux",
            pullRequestNumbers: [7],
            session: session,
            authHeader: "Bearer test-token"
        )
        #expect(statuses == nil)
    }

    @Test func openPullRequestNumbersOnlyIncludesRequestedOpenBranches() {
        let entry = WorkspacePullRequestRepoCacheEntry(
            fetchedAt: Date(),
            pullRequestsByBranch: [
                "feat/open": item(number: 7, state: "OPEN", updatedAt: nil),
                "feat/merged": item(number: 8, state: "MERGED", updatedAt: nil),
                "feat/other": item(number: 9, state: "OPEN", updatedAt: nil),
            ]
        )
        let service = PullRequestProbeService()
        #expect(service.openPullRequestNumbers(
            in: entry,
            candidateBranches: ["feat/open", "feat/merged", "feat/missing"]
        ) == Set([7]))
    }

    @Test func cacheEntrySatisfiesCIRequestsOnlyWhenRollupsWereIncluded() {
        let now = Date(timeIntervalSince1970: 1_000)
        let plain = WorkspacePullRequestRepoCacheEntry(fetchedAt: now, pullRequestsByBranch: [:])
        let withCI = WorkspacePullRequestRepoCacheEntry(
            fetchedAt: now,
            pullRequestsByBranch: [:],
            includesCIStatus: true,
            ciStatusByPullRequestNumber: [7: .success]
        )
        let service = PullRequestProbeService()
        #expect(service.cachedEntrySatisfiesRequest(plain, now: now, includeCIStatus: false))
        #expect(!service.cachedEntrySatisfiesRequest(plain, now: now, includeCIStatus: true))
        #expect(service.cachedEntrySatisfiesRequest(withCI, now: now, includeCIStatus: true))
        #expect(service.cachedEntrySatisfiesRequest(
            withCI,
            now: now,
            includeCIStatus: true,
            pullRequestNumbers: [7]
        ))
        #expect(!service.cachedEntrySatisfiesRequest(
            withCI,
            now: now,
            includeCIStatus: true,
            pullRequestNumbers: [7, 8]
        ))
    }

    @Test func tokenlessCIStatusFetchReturnsNeutralRollupsWithoutNetwork() async {
        let service = PullRequestProbeService()
        let statuses = await service.pullRequestCIStatusesByNumber(
            repoSlug: "manaflow-ai/cmux",
            pullRequestNumbers: [7],
            session: .shared,
            authHeader: nil
        )
        #expect(statuses == [7: .neutral])
    }

    @Test func ciUnavailableCacheEntryStillSatisfiesCIRequestWithNeutralStatuses() async {
        let now = Date(timeIntervalSince1970: 1_000)
        let entry = WorkspacePullRequestRepoCacheEntry(
            fetchedAt: now,
            pullRequestsByBranch: [
                "feat/x": item(number: 7, state: "OPEN", updatedAt: nil, ciStatus: .success),
            ]
        )
        let service = PullRequestProbeService()
        let cacheEntry = await service.repoCacheEntry(
            entry,
            repoSlug: "manaflow-ai/cmux",
            fetchTimestamp: now,
            session: .shared,
            authHeader: nil,
            includeCIStatus: true,
            pullRequestNumbers: [7]
        )

        #expect(cacheEntry.includesCIStatus)
        #expect(cacheEntry.ciStatusByPullRequestNumber[7] == .neutral)
        #expect(cacheEntry.pullRequestsByBranch["feat/x"]?.ciStatus == .neutral)
        #expect(service.cachedEntrySatisfiesRequest(cacheEntry, now: now, includeCIStatus: true))
    }

    @Test func transientCIStatusFetchFailureLeavesMissingNumbersUncached() async throws {
        let session = Self.mockSession()
        PullRequestCIMockURLProtocol.handler = { request in
            try Self.graphQLResponse(request: request, statusCode: 500, json: "")
        }
        defer { PullRequestCIMockURLProtocol.handler = nil }

        let now = Date(timeIntervalSince1970: 1_000)
        let entry = WorkspacePullRequestRepoCacheEntry(
            fetchedAt: now,
            pullRequestsByBranch: [
                "feat/x": item(number: 7, state: "OPEN", updatedAt: nil),
            ]
        )
        let service = PullRequestProbeService()
        let cacheEntry = await service.repoCacheEntry(
            entry,
            repoSlug: "manaflow-ai/cmux",
            fetchTimestamp: now,
            session: session,
            authHeader: "Bearer test-token",
            includeCIStatus: true,
            pullRequestNumbers: [7]
        )

        #expect(!cacheEntry.includesCIStatus)
        #expect(cacheEntry.ciStatusByPullRequestNumber[7] == nil)
        #expect(!service.cachedEntrySatisfiesRequest(
            cacheEntry,
            now: now,
            includeCIStatus: true,
            pullRequestNumbers: [7]
        ))
    }

    @Test func partialGraphQLErrorLeavesMissingStatusesUncached() async throws {
        let session = Self.mockSession()
        PullRequestCIMockURLProtocol.handler = { request in
            try Self.graphQLResponse(
                request: request,
                json: """
                {
                  "data": {
                    "repository": {
                      "pr0": {"number": 7, "commits": {"nodes": [{"commit": {"statusCheckRollup": {"state": "SUCCESS"}}}]}}
                    }
                  },
                  "errors": [{"message": "pr1 status unavailable"}]
                }
                """
            )
        }
        defer { PullRequestCIMockURLProtocol.handler = nil }

        let now = Date(timeIntervalSince1970: 1_000)
        let entry = WorkspacePullRequestRepoCacheEntry(
            fetchedAt: now,
            pullRequestsByBranch: [
                "feat/a": item(number: 7, state: "OPEN", updatedAt: nil),
                "feat/b": item(number: 8, state: "OPEN", updatedAt: nil, ciStatus: .failure),
            ]
        )
        let service = PullRequestProbeService()
        let cacheEntry = await service.repoCacheEntry(
            entry,
            repoSlug: "manaflow-ai/cmux",
            fetchTimestamp: now,
            session: session,
            authHeader: "Bearer test-token",
            includeCIStatus: true,
            pullRequestNumbers: [7, 8]
        )

        #expect(cacheEntry.ciStatusByPullRequestNumber == [7: .success])
        #expect(cacheEntry.pullRequestsByBranch["feat/a"]?.ciStatus == .success)
        #expect(cacheEntry.pullRequestsByBranch["feat/b"]?.ciStatus == .failure)
        #expect(!service.cachedEntrySatisfiesRequest(
            cacheEntry,
            now: now,
            includeCIStatus: true,
            pullRequestNumbers: [7, 8]
        ))
    }

    @Test func ciCacheEntryKeepsExistingStatusesAndFillsNewMissingNumbersNeutral() async {
        let now = Date(timeIntervalSince1970: 1_000)
        let entry = WorkspacePullRequestRepoCacheEntry(
            fetchedAt: now,
            pullRequestsByBranch: [
                "feat/a": item(number: 7, state: "OPEN", updatedAt: nil),
                "feat/b": item(number: 8, state: "OPEN", updatedAt: nil),
            ],
            includesCIStatus: true,
            ciStatusByPullRequestNumber: [7: .success]
        )
        let service = PullRequestProbeService()
        let cacheEntry = await service.repoCacheEntry(
            entry,
            repoSlug: "manaflow-ai/cmux",
            fetchTimestamp: now,
            session: .shared,
            authHeader: nil,
            includeCIStatus: true,
            pullRequestNumbers: [7, 8]
        )

        #expect(cacheEntry.ciStatusByPullRequestNumber[7] == .success)
        #expect(cacheEntry.ciStatusByPullRequestNumber[8] == .neutral)
        #expect(cacheEntry.pullRequestsByBranch["feat/a"]?.ciStatus == .success)
        #expect(cacheEntry.pullRequestsByBranch["feat/b"]?.ciStatus == .neutral)
    }

    private static func mockSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PullRequestCIMockURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private static func graphQLResponse(
        request: URLRequest,
        statusCode: Int = 200,
        json: String
    ) throws -> (HTTPURLResponse, Data) {
        guard let url = request.url else {
            throw URLError(.badURL)
        }
        guard let response = HTTPURLResponse(
            url: url,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: nil
        ) else {
            throw URLError(.badServerResponse)
        }
        return (response, Data(json.utf8))
    }
}
