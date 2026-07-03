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
        ciStatus: PullRequestCheckStatus = .neutral
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
        #expect(items[1].ciStatus == .neutral)
    }

    @Test func checkStatusMapsGitHubRollupStates() {
        #expect(PullRequestCheckStatus(githubStatusCheckRollupState: "SUCCESS") == .success)
        #expect(PullRequestCheckStatus(githubStatusCheckRollupState: "failure") == .failure)
        #expect(PullRequestCheckStatus(githubStatusCheckRollupState: "ERROR") == .failure)
        #expect(PullRequestCheckStatus(githubStatusCheckRollupState: "PENDING") == .neutral)
        #expect(PullRequestCheckStatus(githubStatusCheckRollupState: "EXPECTED") == .neutral)
        #expect(PullRequestCheckStatus(githubStatusCheckRollupState: nil) == .neutral)
    }

    @Test func probeItemDecodingDefaultsUnknownCIStatusToNeutral() throws {
        let json = """
        {
          "number": 7,
          "state": "OPEN",
          "url": "https://github.com/manaflow-ai/cmux/pull/7",
          "updatedAt": "2026-06-03T10:00:00Z",
          "ciStatus": "future-status"
        }
        """
        let item = try JSONDecoder().decode(
            GitHubPullRequestProbeItem.self,
            from: Data(json.utf8)
        )
        #expect(item.ciStatus == .neutral)
    }

    @Test func decodesGraphQLCheckRollupStatuses() throws {
        let json = """
        {
          "data": {
            "repository": {
              "pullRequests": {
                "nodes": [
                  {
                    "number": 7,
                    "headRefName": "feature/pass",
                    "commits": {
                      "nodes": [
                        {"commit": {"statusCheckRollup": {"state": "SUCCESS"}}}
                      ]
                    }
                  },
                  {
                    "number": 8,
                    "headRefName": "feature/fail",
                    "commits": {
                      "nodes": [
                        {"commit": {"statusCheckRollup": {"state": "ERROR"}}}
                      ]
                    }
                  },
                  {
                    "number": 9,
                    "headRefName": "feature/pending",
                    "commits": {
                      "nodes": [
                        {"commit": {"statusCheckRollup": {"state": "EXPECTED"}}}
                      ]
                    }
                  }
                ]
              }
            }
          }
        }
        """
        let response = try #require(
            PullRequestProbeService.decodeJSON(
                WorkspacePullRequestGraphQLResponse.self,
                from: Data(json.utf8)
            )
        )

        let statuses = PullRequestProbeService.checkStatusesByPullRequestNumber(from: response)
        #expect(statuses[7] == .success)
        #expect(statuses[8] == .failure)
        #expect(statuses[9] == .neutral)
    }

    // MARK: branch-lookup CI status

    @Test func branchLookupAppliesFetchedCheckStatusToFoundPullRequests() {
        // A PR resolved only by the targeted `head=` branch lookup is absent
        // from the candidate-matched recent REST window, so the recent GraphQL
        // fetch never covered it. Its freshly fetched rollup must still be
        // applied instead of defaulting to `.neutral`.
        let baseEntry = WorkspacePullRequestRepoCacheEntry(
            fetchedAt: Date(),
            pullRequestsByBranch: [:]
        )
        let found = item(
            number: 4242,
            state: "OPEN",
            url: "https://github.com/manaflow-ai/cmux/pull/4242",
            updatedAt: "2026-03-20T18:00:00Z",
            headRefName: "feature/branch-lookup"
        )
        let outcome = PullRequestProbeService.foldingBranchLookupResults(
            [("feature/branch-lookup", .found(found))],
            fetchedCheckStatuses: [4242: .success],
            into: baseEntry,
            refreshedAt: Date()
        )
        #expect(
            outcome.cacheEntry.pullRequestsByBranch["feature/branch-lookup"]?.ciStatus == .success
        )
    }

    @Test func branchLookupKeepsNeutralWhenNoCheckStatusAvailable() {
        let baseEntry = WorkspacePullRequestRepoCacheEntry(
            fetchedAt: Date(),
            pullRequestsByBranch: [:]
        )
        let found = item(
            number: 7,
            state: "OPEN",
            url: "https://github.com/manaflow-ai/cmux/pull/7",
            updatedAt: "2026-03-20T18:00:00Z",
            headRefName: "feature/none"
        )
        let outcome = PullRequestProbeService.foldingBranchLookupResults(
            [("feature/none", .found(found))],
            fetchedCheckStatuses: [:],
            into: baseEntry,
            refreshedAt: Date()
        )
        #expect(
            outcome.cacheEntry.pullRequestsByBranch["feature/none"]?.ciStatus == .neutral
        )
    }

    @Test func decodesAliasedGraphQLCheckRollupStatuses() throws {
        let json = """
        {
          "data": {
            "repository": {
              "pr0": {
                "number": 7,
                "headRefName": "feature/pass",
                "commits": {
                  "nodes": [
                    {"commit": {"statusCheckRollup": {"state": "SUCCESS"}}}
                  ]
                }
              },
              "pr1": {
                "number": 108,
                "headRefName": "feature/fail",
                "commits": {
                  "nodes": [
                    {"commit": {"statusCheckRollup": {"state": "FAILURE"}}}
                  ]
                }
              }
            }
          }
        }
        """
        let response = try #require(
            PullRequestProbeService.decodeJSON(
                WorkspacePullRequestGraphQLResponse.self,
                from: Data(json.utf8)
            )
        )

        let statuses = PullRequestProbeService.checkStatusesByPullRequestNumber(from: response)
        #expect(statuses[7] == .success)
        #expect(statuses[108] == .failure)
    }

    @Test func aliasedGraphQLCheckRollupToleratesNullAliases() throws {
        let json = """
        {
          "data": {
            "repository": {
              "pr0": null,
              "pr1": {
                "number": 108,
                "headRefName": "feature/fail",
                "commits": {
                  "nodes": [
                    {"commit": {"statusCheckRollup": {"state": "FAILURE"}}}
                  ]
                }
              }
            }
          }
        }
        """
        let response = try #require(
            PullRequestProbeService.decodeJSON(
                WorkspacePullRequestGraphQLResponse.self,
                from: Data(json.utf8)
            )
        )

        let statuses = PullRequestProbeService.checkStatusesByPullRequestNumber(from: response)
        #expect(statuses[108] == .failure)
    }

    @Test func aliasedGraphQLCheckRollupRejectsMalformedAliasObjects() {
        let json = """
        {
          "data": {
            "repository": {
              "pr0": {
                "number": "not-a-number",
                "headRefName": "feature/bad",
                "commits": {
                  "nodes": [
                    {"commit": {"statusCheckRollup": {"state": "SUCCESS"}}}
                  ]
                }
              }
            }
          }
        }
        """
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(
                WorkspacePullRequestGraphQLResponse.self,
                from: Data(json.utf8)
            )
        }
    }

    @Test func checkStatusQueryTargetsExactOpenPullRequestNumbers() {
        let open = item(
            number: 7,
            state: "OPEN",
            updatedAt: "2026-06-01T00:00:00Z"
        )
        let duplicateOpen = item(
            number: 7,
            state: "open",
            updatedAt: "2026-06-01T00:00:00Z"
        )
        let merged = item(
            number: 8,
            state: "MERGED",
            updatedAt: "2026-06-01T00:00:00Z"
        )
        let secondOpen = item(
            number: 108,
            state: "OPEN",
            updatedAt: "2026-06-01T00:00:00Z"
        )

        let numbers = PullRequestProbeService.checkStatusPullRequestNumbers(
            from: [open, duplicateOpen, merged, secondOpen]
        )
        #expect(numbers == [7, 108])

        let query = PullRequestProbeService.checkStatusGraphQLQuery(pullRequestNumbers: numbers)
        #expect(query.contains("pr0: pullRequest(number: 7)"))
        #expect(query.contains("pr1: pullRequest(number: 108)"))
        #expect(!query.contains("pullRequests(states:"))
    }

    @Test func applyingCheckStatusesUsesNumberMatches() {
        let passing = item(
            number: 7,
            state: "OPEN",
            url: "https://github.com/o/r/pull/7",
            updatedAt: "2026-06-01T00:00:00Z",
            headRefName: "feature/pass"
        )
        let unknown = item(
            number: 8,
            state: "OPEN",
            url: "https://github.com/o/r/pull/8",
            updatedAt: "2026-06-01T00:00:00Z",
            headRefName: "feature/unknown"
        )
        let branchMatched = item(
            number: 9,
            state: "OPEN",
            url: "https://github.com/o/r/pull/9",
            updatedAt: "2026-06-01T00:00:00Z",
            headRefName: "feature/branch"
        )

        let updated = PullRequestProbeService.applyingCheckStatuses(
            [7: .success, 9: .failure],
            to: [passing, unknown, branchMatched]
        )

        #expect(updated[0].ciStatus == .success)
        #expect(updated[1].ciStatus == .neutral)
        #expect(updated[2].ciStatus == .failure)
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

    // MARK: result resolution

    @Test func resolveRefreshResultsMatchesPrefersAndPropagatesFailures() {
        let wsA = UUID(), wsB = UUID(), wsC = UUID(), panel = UUID()
        let pr = item(
            number: 7,
            state: "OPEN",
            url: "https://github.com/o/r/pull/7",
            updatedAt: "2026-06-01T00:00:00Z",
            headRefName: "feat/x",
            ciStatus: .failure
        )
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
        #expect(resolved.ciStatusRawValue == PullRequestCheckStatus.failure.rawValue)

        guard case .transientFailure = results[1].resolution else {
            Issue.record("expected transientFailure for branch with transient lookup")
            return
        }
        guard case .unsupportedRepository = results[2].resolution else {
            Issue.record("expected unsupportedRepository for empty slugs")
            return
        }
    }
}
