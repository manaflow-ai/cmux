import Foundation
import Testing
@testable import CmuxGit

/// Pure pull-request probe logic. The selection/policy cases are migrated from
/// the app target's `TabManagerPullRequestProbeTests`, where they tested the
/// same logic as TabManager statics before the extraction.
@Suite struct PullRequestProbeServiceTests {
    private func item(
        number: Int,
        state: String,
        url: String = "https://github.com/manaflow-ai/cmux/pull/1",
        updatedAt: String?,
        mergedAt: String? = nil,
        headRefName: String? = nil,
        baseRefName: String? = nil,
        ciStatus: PullRequestCIStatus = .neutral
    ) -> GitHubPullRequestProbeItem {
        GitHubPullRequestProbeItem(
            number: number,
            state: state,
            url: url,
            updatedAt: updatedAt,
            mergedAt: mergedAt,
            headRefName: headRefName,
            baseRefName: baseRefName,
            ciStatus: ciStatus
        )
    }

    // MARK: preferredPullRequest

    @Test func preferredPullRequestPrefersOpenOverMergedAndClosed() {
        let candidates = [
            item(number: 1889, state: "MERGED", url: "https://github.com/manaflow-ai/cmux/pull/1889", updatedAt: "2026-03-20T18:00:00Z"),
            item(number: 1891, state: "OPEN", url: "https://github.com/manaflow-ai/cmux/pull/1891", updatedAt: "2026-03-19T18:00:00Z"),
            item(number: 1800, state: "CLOSED", url: "https://github.com/manaflow-ai/cmux/pull/1800", updatedAt: "2026-03-21T18:00:00Z"),
        ]
        #expect(PullRequestProbeService.preferredPullRequest(from: candidates) == candidates[1])
    }

    @Test func preferredPullRequestPrefersMostRecentlyUpdatedWithinSameStatus() {
        let olderOpen = item(number: 1880, state: "OPEN", url: "https://github.com/manaflow-ai/cmux/pull/1880", updatedAt: "2026-03-18T18:00:00Z")
        let newerOpen = item(number: 1890, state: "OPEN", url: "https://github.com/manaflow-ai/cmux/pull/1890", updatedAt: "2026-03-20T18:00:00Z")
        #expect(PullRequestProbeService.preferredPullRequest(from: [olderOpen, newerOpen]) == newerOpen)
    }

    @Test func preferredPullRequestIgnoresMalformedCandidates() {
        let valid = item(number: 1888, state: "OPEN", url: "https://github.com/manaflow-ai/cmux/pull/1888", updatedAt: "2026-03-20T18:00:00Z")
        let preferred = PullRequestProbeService.preferredPullRequest(from: [
            item(number: 9999, state: "WHATEVER", url: "https://github.com/manaflow-ai/cmux/pull/9999", updatedAt: "2026-03-21T18:00:00Z"),
            // An empty URL string is rejected by URL(string:) on every macOS;
            // "not a url" is only rejected by pre-macOS-14-SDK parsing (the
            // lenient parser percent-encodes it), so it is not a stable fixture.
            item(number: 10000, state: "OPEN", url: "", updatedAt: "2026-03-21T18:00:00Z"),
            valid,
        ])
        #expect(preferred == valid)
    }

    // MARK: branch map + staleness

    @Test func pullRequestMapDropsStaleMergedHeadPullRequestForLongLivedBaseBranch() throws {
        let now = try #require(ISO8601DateFormatter().date(from: "2026-04-20T12:00:00Z"))
        let pullRequests = [
            item(number: 2400, state: "MERGED", url: "https://github.com/manaflow-ai/cmux/pull/2400", updatedAt: "2026-03-06T12:00:00Z", mergedAt: "2026-03-06T12:00:00Z", headRefName: "develop", baseRefName: "main"),
            item(number: 2501, state: "MERGED", url: "https://github.com/manaflow-ai/cmux/pull/2501", updatedAt: "2026-04-19T12:00:00Z", mergedAt: "2026-04-19T12:00:00Z", headRefName: "feature/recent-one", baseRefName: "develop"),
            item(number: 2502, state: "OPEN", url: "https://github.com/manaflow-ai/cmux/pull/2502", updatedAt: "2026-04-20T12:00:00Z", headRefName: "feature/recent-two", baseRefName: "develop"),
        ]

        let byBranch = PullRequestProbeService.pullRequestMapByNormalizedBranch(from: pullRequests, now: now)
        #expect(byBranch["develop"] == nil)
        #expect(byBranch["feature/recent-one"]?.number == 2501)
        #expect(byBranch["feature/recent-two"]?.number == 2502)
    }

    // MARK: refresh policy

    @Test func shouldSkipLookupOnlyForExactMainAndMaster() {
        #expect(PullRequestProbeService.shouldSkipLookup(branch: "main"))
        #expect(PullRequestProbeService.shouldSkipLookup(branch: "master"))
        #expect(PullRequestProbeService.shouldSkipLookup(branch: " master \n"))

        #expect(!PullRequestProbeService.shouldSkipLookup(branch: "Main"))
        #expect(!PullRequestProbeService.shouldSkipLookup(branch: "mainline"))
        #expect(!PullRequestProbeService.shouldSkipLookup(branch: "feature/main"))
        #expect(!PullRequestProbeService.shouldSkipLookup(branch: "release/master-fix"))
    }

    @Test func refreshAllowsRepoCacheForTimerAndPeriodicReasons() {
        for reason in ["periodicPoll", "periodicPoll.followUp", "selectedPeriodicPoll", "selectedPeriodicPoll.followUp", "timer", "timer.followUp"] {
            #expect(PullRequestProbeService.refreshAllowsRepoCache(reason: reason), "\(reason) should allow cache")
        }
        for reason in ["branchChange", "branchChange.followUp", "shellPrompt", "commandHint:merge"] {
            #expect(!PullRequestProbeService.refreshAllowsRepoCache(reason: reason), "\(reason) should bypass cache")
        }
    }

    @Test func shouldRefreshHonorsForcedRefreshForTerminalStates() {
        let now = Date(timeIntervalSince1970: 1_000)
        let recentTerminalRefresh = now.addingTimeInterval(-60)

        #expect(PullRequestProbeService.shouldRefresh(
            now: now,
            nextPollAt: .distantPast,
            lastTerminalStateRefreshAt: recentTerminalRefresh,
            currentStatus: .merged
        ))
        #expect(!PullRequestProbeService.shouldRefresh(
            now: now,
            nextPollAt: now.addingTimeInterval(60),
            lastTerminalStateRefreshAt: recentTerminalRefresh,
            currentStatus: .closed
        ))
    }

    // MARK: REST decode + mapping

    @Test func decodesRESTItemsAndSynthesizesMergedState() throws {
        let json = """
        [
          {
            "number": 5277,
            "state": "closed",
            "html_url": "https://github.com/manaflow-ai/cmux/pull/5277",
            "updated_at": "2026-06-03T10:00:00Z",
            "merged_at": "2026-06-03T10:00:00Z",
            "head": {"ref": "feat-cmux-git"},
            "base": {"ref": "main"}
          },
          {
            "number": 5293,
            "state": "open",
            "html_url": "https://github.com/manaflow-ai/cmux/pull/5293",
            "updated_at": "2026-06-03T11:00:00Z",
            "merged_at": null,
            "head": {"ref": "feat-packages-tools-62"},
            "base": null
          }
        ]
        """
        let rest = try #require(
            PullRequestProbeService.decodeJSON([WorkspacePullRequestRESTItem].self, from: Data(json.utf8))
        )
        let items = rest.map(PullRequestProbeService.probeItem)

        // merged_at set -> state synthesized to MERGED regardless of raw state
        #expect(items[0].state == "MERGED")
        #expect(PullRequestStatus(githubState: items[0].state) == .merged)
        #expect(items[0].headRefName == "feat-cmux-git")
        #expect(items[0].baseRefName == "main")

        #expect(items[1].state == "open")
        #expect(PullRequestStatus(githubState: items[1].state) == .open)
        #expect(items[1].baseRefName == nil)
        #expect(items[1].url == "https://github.com/manaflow-ai/cmux/pull/5293")
    }

    @Test func branchEndpointEncodesHeadFilterAndRejectsMalformedSlugs() throws {
        let endpoint = try #require(
            PullRequestProbeService.branchEndpoint(repoSlug: "manaflow-ai/cmux", branch: "feat/x")
        )
        #expect(endpoint.hasPrefix("repos/manaflow-ai/cmux/pulls?"))
        #expect(endpoint.contains("head=manaflow-ai:feat/x") || endpoint.contains("head=manaflow-ai%3Afeat/x") || endpoint.contains("head=manaflow-ai:feat%2Fx"))
        #expect(PullRequestProbeService.branchEndpoint(repoSlug: "no-slash", branch: "b") == nil)
        #expect(PullRequestProbeService.branchEndpoint(repoSlug: "/missing-owner", branch: "b") == nil)
    }

    // MARK: CI status

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

    @Test func graphQLCIStatusResponseDecodesLatestCommitRollups() throws {
        let json = """
        {
          "data": {
            "repository": {
              "pr0": {"number": 1, "commits": {"nodes": [{"commit": {"statusCheckRollup": {"state": "SUCCESS"}}}]}},
              "pr1": {"number": 2, "commits": {"nodes": [{"commit": {"statusCheckRollup": {"state": "ERROR"}}}]}},
              "pr2": {"number": 3, "commits": {"nodes": [{"commit": {"statusCheckRollup": null}}]}},
              "pr3": null
            }
          }
        }
        """
        let response = try #require(
            PullRequestProbeService.decodeJSON(
                GitHubPullRequestCIStatusGraphQLResponse.self,
                from: Data(json.utf8)
            )
        )
        #expect(response.ciStatusesByPullRequestNumber == [1: .success, 2: .failure, 3: .neutral])
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
        #expect(PullRequestProbeService.openPullRequestNumbers(
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
        #expect(PullRequestProbeService.cachedEntrySatisfiesRequest(plain, now: now, includeCIStatus: false))
        #expect(!PullRequestProbeService.cachedEntrySatisfiesRequest(plain, now: now, includeCIStatus: true))
        #expect(PullRequestProbeService.cachedEntrySatisfiesRequest(withCI, now: now, includeCIStatus: true))
        #expect(PullRequestProbeService.cachedEntrySatisfiesRequest(
            withCI,
            now: now,
            includeCIStatus: true,
            pullRequestNumbers: [7]
        ))
        #expect(!PullRequestProbeService.cachedEntrySatisfiesRequest(
            withCI,
            now: now,
            includeCIStatus: true,
            pullRequestNumbers: [7, 8]
        ))
    }

    @Test func tokenlessCIStatusFetchReturnsNeutralEmptyRollupWithoutNetwork() async {
        let service = PullRequestProbeService()
        let statuses = await service.pullRequestCIStatusesByNumber(
            repoSlug: "manaflow-ai/cmux",
            pullRequestNumbers: [7],
            session: .shared,
            authHeader: nil
        )
        #expect(statuses == [:])
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
        #expect(PullRequestProbeService.cachedEntrySatisfiesRequest(cacheEntry, now: now, includeCIStatus: true))
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

    // MARK: result resolution

    @Test func resolveRefreshResultsMatchesPrefersAndPropagatesFailures() {
        let wsA = UUID(), wsB = UUID(), wsC = UUID(), panel = UUID()
        let pr = item(number: 7, state: "OPEN", url: "https://github.com/o/r/pull/7", updatedAt: "2026-06-01T00:00:00Z", headRefName: "feat/x", ciStatus: .success)
        let entry = WorkspacePullRequestRepoCacheEntry(
            fetchedAt: Date(),
            pullRequestsByBranch: ["feat/x": pr]
        )
        let candidates = [
            WorkspacePullRequestCandidate(workspaceId: wsA, panelId: panel, branch: "feat/x", repoSlugs: ["o/r"]),
            WorkspacePullRequestCandidate(workspaceId: wsB, panelId: panel, branch: "feat/missing", repoSlugs: ["o/r"]),
            WorkspacePullRequestCandidate(workspaceId: wsC, panelId: panel, branch: "feat/x", repoSlugs: []),
        ]
        let results = PullRequestProbeService.resolveRefreshResults(
            candidates: candidates,
            repoResults: ["o/r": .success(entry, usedCache: false, transientBranches: ["feat/missing"])]
        )

        guard case .resolved(let resolved) = results[0].resolution else {
            Issue.record("expected resolved, got \(results[0].resolution)")
            return
        }
        #expect(resolved.number == 7)
        #expect(resolved.statusRawValue == PullRequestStatus.open.rawValue)
        #expect(resolved.ciStatus == .success)

        guard case .transientFailure = results[1].resolution else {
            Issue.record("expected transientFailure for branch with transient lookup")
            return
        }
        guard case .unsupportedRepository = results[2].resolution else {
            Issue.record("expected unsupportedRepository for empty slugs")
            return
        }
    }

    @Test func resolveRefreshResultsDropsCIStatusForMergedAndClosedPullRequests() {
        let ws = UUID(), panel = UUID()
        let pr = item(
            number: 8,
            state: "MERGED",
            url: "https://github.com/o/r/pull/8",
            updatedAt: "2026-06-01T00:00:00Z",
            headRefName: "feat/x",
            ciStatus: .failure
        )
        let entry = WorkspacePullRequestRepoCacheEntry(fetchedAt: Date(), pullRequestsByBranch: ["feat/x": pr])
        let results = PullRequestProbeService.resolveRefreshResults(
            candidates: [WorkspacePullRequestCandidate(workspaceId: ws, panelId: panel, branch: "feat/x", repoSlugs: ["o/r"])],
            repoResults: ["o/r": .success(entry, usedCache: false, transientBranches: [])]
        )

        guard case .resolved(let resolved) = results[0].resolution else {
            Issue.record("expected resolved, got \(results[0].resolution)")
            return
        }
        #expect(resolved.statusRawValue == PullRequestStatus.merged.rawValue)
        #expect(resolved.ciStatus == .neutral)
    }
}
