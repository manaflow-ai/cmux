import Foundation
import Testing
import CmuxProcess
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
        baseRefName: String? = nil
    ) -> GitHubPullRequestProbeItem {
        GitHubPullRequestProbeItem(
            number: number,
            state: state,
            url: url,
            updatedAt: updatedAt,
            mergedAt: mergedAt,
            headRefName: headRefName,
            baseRefName: baseRefName
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
        let reference = GitHubRepositoryReference(host: .dotCom, owner: "manaflow-ai", repo: "cmux")
        let endpoint = try #require(
            PullRequestProbeService.branchEndpoint(reference: reference, branch: "feat/x")
        )
        #expect(endpoint.hasPrefix("repos/manaflow-ai/cmux/pulls?"))
        #expect(endpoint.contains("head=manaflow-ai:feat/x") || endpoint.contains("head=manaflow-ai%3Afeat/x") || endpoint.contains("head=manaflow-ai:feat%2Fx"))
        #expect(PullRequestProbeService.branchEndpoint(reference: GitHubRepositoryReference(host: .dotCom, owner: "", repo: "r"), branch: "b") == nil)
        #expect(PullRequestProbeService.branchEndpoint(reference: GitHubRepositoryReference(host: .dotCom, owner: "o", repo: ""), branch: "b") == nil)
    }

    @Test func enterpriseAuthTokenLookupPassesHostnameToGh() async {
        let recorder = CommandRunnerRecorder(stdout: "ghs_enterprise\n")
        let service = PullRequestProbeService(commandRunner: recorder, environment: [:])

        let token = await service.authToken(for: GitHubHost(hostname: "ghe.example.com"))

        #expect(token == "ghs_enterprise")
        #expect(await recorder.invocations.map(\.arguments) == [
            ["auth", "token", "--hostname", "ghe.example.com"],
        ])
    }

    @Test func enterprisePortQualifiedHostUsesOriginConsistentTokenLookup() async {
        // The credential lookup must match the origin requests target, so a
        // non-default-port host asks gh for `host:port`, not the bare hostname.
        let recorder = CommandRunnerRecorder(stdout: "stored-host-token\n")
        let service = PullRequestProbeService(commandRunner: recorder, environment: [:])

        let token = await service.authToken(for: GitHubHost(hostname: "ghe.example.com", port: 8443))

        #expect(token == "stored-host-token")
        #expect(await recorder.invocations.map(\.arguments) == [
            ["auth", "token", "--hostname", "ghe.example.com:8443"],
        ])
    }

    @Test func authTokensByHostCapsTokenProbeFanOut() async {
        // A repo config with many distinct hosts must not fork an unbounded
        // number of gh processes; the probe count is capped.
        let recorder = CommandRunnerRecorder(stdout: "stored-host-token\n")
        let service = PullRequestProbeService(commandRunner: recorder, environment: [:])
        let hosts = Set((0..<40).map { GitHubHost(hostname: "ghe-\($0).example.com") })

        let tokens = await service.authTokensByHost(for: hosts)

        #expect(tokens.count == PullRequestProbeService.maxTokenProbeHosts)
        #expect(await recorder.invocations.count == PullRequestProbeService.maxTokenProbeHosts)
    }

    @Test func authTokenRefusesAmbientEnterpriseTokenForUnverifiedHost() async {
        // `gh auth token --hostname <anything>` returns GH_ENTERPRISE_TOKEN for
        // any non-github.com host, so a remote pointing at an attacker host must
        // not be sent the ambient enterprise credential.
        let recorder = CommandRunnerRecorder(stdout: "ambient-secret\n")
        let service = PullRequestProbeService(
            commandRunner: recorder,
            environment: ["GH_ENTERPRISE_TOKEN": "ambient-secret"]
        )

        let token = await service.authToken(for: GitHubHost(hostname: "evil.example.com"))

        #expect(token == nil)
    }

    @Test func authTokenRefusesAmbientPublicTokenForNonDotComHost() async {
        // gh hands GH_TOKEN/GITHUB_TOKEN to *.ghe.com hosts, so an ambient public
        // GitHub token must not be sent to a non-github.com host either.
        let recorder = CommandRunnerRecorder(stdout: "gho_public\n")
        let service = PullRequestProbeService(
            commandRunner: recorder,
            environment: ["GH_TOKEN": "gho_public"]
        )

        let token = await service.authToken(for: GitHubHost(hostname: "attacker.ghe.com"))

        #expect(token == nil)
    }

    @Test func authTokenTrustsAmbientTokenBoundToHostViaGHHost() async {
        // GH_HOST marks the host the ambient env token is intentionally for, so
        // the common GH_HOST + GH_ENTERPRISE_TOKEN setup must keep working.
        let recorder = CommandRunnerRecorder(stdout: "ghs_enterprise\n")
        let service = PullRequestProbeService(
            commandRunner: recorder,
            environment: ["GH_ENTERPRISE_TOKEN": "ghs_enterprise", "GH_HOST": "ghe.example.com"]
        )

        let token = await service.authToken(for: GitHubHost(hostname: "ghe.example.com"))

        #expect(token == "ghs_enterprise")
    }

    @Test func dotComTokenLookupIgnoresCloneProxyPort() async {
        // github.com credentials are stored for the bare host, so a clone proxy
        // port must not leak into the gh hostname lookup.
        let recorder = CommandRunnerRecorder(stdout: "gho_token\n")
        let service = PullRequestProbeService(commandRunner: recorder, environment: [:])

        let token = await service.authToken(for: GitHubHost(hostname: "github.com", port: 8080))

        #expect(token == "gho_token")
        #expect(await recorder.invocations.map(\.arguments) == [
            ["auth", "token", "--hostname", "github.com"],
        ])
    }

    @Test func authTokenTrustsPerHostStoredEnterpriseToken() async {
        // A per-host credential from `gh auth login --hostname` differs from the
        // ambient enterprise env token, so it is trusted and used.
        let recorder = CommandRunnerRecorder(stdout: "stored-host-token\n")
        let service = PullRequestProbeService(
            commandRunner: recorder,
            environment: ["GH_ENTERPRISE_TOKEN": "ambient-secret"]
        )

        let token = await service.authToken(for: GitHubHost(hostname: "ghe.example.com"))

        #expect(token == "stored-host-token")
    }

    @Test func hostPollabilityGatesEnterpriseWithoutToken() {
        #expect(GitHubHost.dotCom.isPollable(token: nil))
        #expect(GitHubHost(hostname: "ghe.example.com").isPollable(token: "ghs_enterprise"))
        #expect(!GitHubHost(hostname: "ghe.example.com").isPollable(token: nil))
        #expect(!GitHubHost(hostname: "gitlab.com").isPollable(token: nil))
    }

    // MARK: result resolution

    @Test func resolveRefreshResultsMatchesPrefersAndPropagatesFailures() {
        let wsA = UUID(), wsB = UUID(), wsC = UUID(), panel = UUID()
        let pr = item(number: 7, state: "OPEN", url: "https://github.com/o/r/pull/7", updatedAt: "2026-06-01T00:00:00Z", headRefName: "feat/x")
        let reference = GitHubRepositoryReference(host: .dotCom, owner: "o", repo: "r")
        let entry = WorkspacePullRequestRepoCacheEntry(
            fetchedAt: Date(),
            pullRequestsByBranch: ["feat/x": pr]
        )
        let candidates = [
            WorkspacePullRequestCandidate(workspaceId: wsA, panelId: panel, branch: "feat/x", repoReferences: [reference]),
            WorkspacePullRequestCandidate(workspaceId: wsB, panelId: panel, branch: "feat/missing", repoReferences: [reference]),
            WorkspacePullRequestCandidate(workspaceId: wsC, panelId: panel, branch: "feat/x", repoReferences: []),
        ]
        let results = PullRequestProbeService.resolveRefreshResults(
            candidates: candidates,
            repoResults: [reference: .success(entry, usedCache: false, transientBranches: ["feat/missing"])]
        )

        guard case .resolved(let resolved) = results[0].resolution else {
            Issue.record("expected resolved, got \(results[0].resolution)")
            return
        }
        #expect(resolved.number == 7)
        #expect(resolved.statusRawValue == PullRequestStatus.open.rawValue)

        guard case .transientFailure = results[1].resolution else {
            Issue.record("expected transientFailure for branch with transient lookup")
            return
        }
        guard case .unsupportedRepository = results[2].resolution else {
            Issue.record("expected unsupportedRepository for empty references")
            return
        }
    }

    @Test func resolveRefreshResultsTreatsAllSkippedReferencesAsUnsupported() {
        let candidate = WorkspacePullRequestCandidate(
            workspaceId: UUID(),
            panelId: UUID(),
            branch: "feat/x",
            repoReferences: [GitHubRepositoryReference(host: GitHubHost(hostname: "gitlab.com"), owner: "o", repo: "r")]
        )

        let result = PullRequestProbeService.resolveRefreshResults(candidates: [candidate], repoResults: [:])

        guard case .unsupportedRepository = result[0].resolution else {
            Issue.record("expected unsupportedRepository for a reference skipped before fetch")
            return
        }
    }
}

private struct CommandInvocation: Sendable, Equatable {
    let executable: String
    let arguments: [String]
}

private actor CommandRunnerRecorder: CommandRunning {
    private let stdout: String?
    private var recordedInvocations: [CommandInvocation] = []

    init(stdout: String?) {
        self.stdout = stdout
    }

    var invocations: [CommandInvocation] {
        recordedInvocations
    }

    func run(
        directory: String,
        executable: String,
        arguments: [String],
        timeout: TimeInterval?
    ) async -> CommandResult {
        recordedInvocations.append(CommandInvocation(executable: executable, arguments: arguments))
        return CommandResult(
            stdout: stdout,
            stderr: "",
            exitStatus: stdout == nil ? 1 : 0,
            timedOut: false,
            executionError: nil
        )
    }
}
