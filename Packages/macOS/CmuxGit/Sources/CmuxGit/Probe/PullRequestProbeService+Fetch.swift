public import Foundation

extension PullRequestProbeService {
    // MARK: Stage 2 — repository fetch

    /// Fetches pull-request data for every repository the candidates need.
    ///
    /// Repositories are fetched concurrently. A repository whose cached entry is
    /// fresh (younger than ``repoCacheLifetime``) and already covers every
    /// candidate branch is served from cache when `allowCachedResults` permits;
    /// otherwise the recent-PRs pages are fetched and any still-unresolved
    /// branches get targeted per-branch lookups.
    ///
    /// - Parameters:
    ///   - repoDirectoriesBySlug: Repositories to fetch (slug → representative directory).
    ///   - candidateBranchesByRepo: The branches each repository must resolve.
    ///   - cacheBySlug: The caller-owned repo cache.
    ///   - now: The refresh timestamp used for cache-freshness checks.
    ///   - allowCachedResults: Whether fresh cache entries may satisfy the fetch.
    /// - Returns: One ``WorkspacePullRequestRepoFetchResult`` per repository slug.
    public nonisolated func fetchRepoResults(
        repoDirectoriesBySlug: [String: String],
        candidateBranchesByRepo: [String: Set<String>],
        cacheBySlug: [String: WorkspacePullRequestRepoCacheEntry],
        now: Date,
        allowCachedResults: Bool
    ) async -> [String: WorkspacePullRequestRepoFetchResult] {
        guard !repoDirectoriesBySlug.isEmpty else { return [:] }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = max(Self.probeTimeout, 8)
        configuration.timeoutIntervalForResource = max(Self.probeTimeout, 8)
        let session = URLSession(configuration: configuration)
        let authHeader = await authHeaderValue()
        var results: [String: WorkspacePullRequestRepoFetchResult] = [:]

        let fetchedResults = await withTaskGroup(
            of: (String, WorkspacePullRequestRepoFetchResult).self,
            returning: [(String, WorkspacePullRequestRepoFetchResult)].self
        ) { group in
            for repoSlug in repoDirectoriesBySlug.keys {
                group.addTask {
                    let result = await self.repoFetchResult(
                        repoSlug: repoSlug,
                        candidateBranches: candidateBranchesByRepo[repoSlug] ?? [],
                        cachedEntry: cacheBySlug[repoSlug],
                        useCachedRecentWindow: allowCachedResults
                            && (cacheBySlug[repoSlug].map {
                                now.timeIntervalSince($0.fetchedAt) < Self.repoCacheLifetime
                            } ?? false),
                        session: session,
                        authHeader: authHeader
                    )
                    return (repoSlug, result)
                }
            }

            var collected: [(String, WorkspacePullRequestRepoFetchResult)] = []
            for await result in group {
                collected.append(result)
            }
            return collected
        }

        for (repoSlug, result) in fetchedResults {
            results[repoSlug] = result
        }
        return results
    }

    /// Fetches one repository: serve from cache when permitted and complete,
    /// else page the recent PRs and per-branch-look-up any leftover branches.
    nonisolated func repoFetchResult(
        repoSlug: String,
        candidateBranches: Set<String>,
        cachedEntry: WorkspacePullRequestRepoCacheEntry?,
        useCachedRecentWindow: Bool,
        session: URLSession,
        authHeader: String?
    ) async -> WorkspacePullRequestRepoFetchResult {
        let normalizedCandidateBranches = Set(
            candidateBranches.compactMap(GitMetadataService.normalizedBranchName)
        )

        if useCachedRecentWindow,
           let cachedEntry {
            let unresolvedBranches = Self.unresolvedBranches(
                normalizedCandidateBranches,
                in: cachedEntry
            )
            if unresolvedBranches.isEmpty {
                debugLog(
                    "workspace.prRefresh.repo.cache repo=\(repoSlug) " +
                    "branches=\(cachedEntry.pullRequestsByBranch.count)"
                )
                return .success(cachedEntry, usedCache: true, transientBranches: [])
            }

            let lookupOutcome = await branchLookupOutcome(
                repoSlug: repoSlug,
                candidateBranches: unresolvedBranches,
                baseEntry: cachedEntry,
                refreshedAt: Date(),
                session: session,
                authHeader: authHeader
            )
            debugLog(
                "workspace.prRefresh.repo.cache.miss repo=\(repoSlug) " +
                "branchLookups=\(unresolvedBranches.count) transient=\(lookupOutcome.transientBranches.count)"
            )
            return .success(
                lookupOutcome.cacheEntry,
                usedCache: false,
                transientBranches: lookupOutcome.transientBranches
            )
        }

        let fetchTimestamp = Date()
        var page = 1
        var fetchedPageCount = 0
        var allPullRequests: [GitHubPullRequestProbeItem] = []

        while page <= Self.repoPageLimit {
            let endpoint = "repos/\(repoSlug)/pulls?state=all&sort=updated&direction=desc&per_page=\(Self.repoPageSize)&page=\(page)"
            guard let response = await performRequest(
                session: session,
                endpoint: endpoint,
                authHeader: authHeader
            ) else {
                debugLog("workspace.prRefresh.repo.fail repo=\(repoSlug) page=\(page) status=nil")
                return .transientFailure
            }

            guard response.statusCode == 200,
                  let pullRequests = Self.decodeJSON([WorkspacePullRequestRESTItem].self, from: response.data) else {
                debugLog("workspace.prRefresh.repo.fail repo=\(repoSlug) page=\(page) status=\(response.statusCode)")
                return .transientFailure
            }

            fetchedPageCount += 1
            allPullRequests.append(contentsOf: pullRequests.map(Self.probeItem))
            if pullRequests.count < Self.repoPageSize {
                break
            }
            page += 1
        }

        let checkStatuses = await pullRequestCheckStatuses(
            repoSlug: repoSlug,
            pullRequests: allPullRequests,
            authHeader: authHeader
        )
        let pullRequestsWithCheckStatuses = Self.applyingCheckStatuses(
            checkStatuses,
            to: allPullRequests
        )

        let recentWindowEntry = WorkspacePullRequestRepoCacheEntry(
            fetchedAt: fetchTimestamp,
            pullRequestsByBranch: Self.pullRequestMapByNormalizedBranch(from: pullRequestsWithCheckStatuses)
        )
        let unresolvedBranches = Self.unresolvedBranches(
            normalizedCandidateBranches,
            in: recentWindowEntry
        )
        let lookupOutcome: WorkspacePullRequestBranchLookupOutcome
        if unresolvedBranches.isEmpty {
            lookupOutcome = WorkspacePullRequestBranchLookupOutcome(
                cacheEntry: recentWindowEntry,
                transientBranches: []
            )
        } else {
            lookupOutcome = await branchLookupOutcome(
                repoSlug: repoSlug,
                candidateBranches: unresolvedBranches,
                baseEntry: recentWindowEntry,
                refreshedAt: fetchTimestamp,
                session: session,
                authHeader: authHeader
            )
        }
        debugLog(
            "workspace.prRefresh.repo.success repo=\(repoSlug) pages=\(fetchedPageCount) " +
            "branches=\(lookupOutcome.cacheEntry.pullRequestsByBranch.count) " +
            "branchLookups=\(unresolvedBranches.count) transient=\(lookupOutcome.transientBranches.count)"
        )
        return .success(
            lookupOutcome.cacheEntry,
            usedCache: false,
            transientBranches: lookupOutcome.transientBranches
        )
    }

    /// The candidate branches a cache entry neither resolves nor positively
    /// marks absent, sorted for deterministic lookup order.
    nonisolated static func unresolvedBranches(
        _ candidateBranches: Set<String>,
        in cacheEntry: WorkspacePullRequestRepoCacheEntry
    ) -> [String] {
        candidateBranches
            .filter {
                cacheEntry.pullRequestsByBranch[$0] == nil
                    && !cacheEntry.knownAbsentBranches.contains($0)
            }
            .sorted()
    }

    /// Runs concurrent per-branch lookups and folds them into a new cache entry.
    nonisolated func branchLookupOutcome(
        repoSlug: String,
        candidateBranches: [String],
        baseEntry: WorkspacePullRequestRepoCacheEntry,
        refreshedAt: Date,
        session: URLSession,
        authHeader: String?
    ) async -> WorkspacePullRequestBranchLookupOutcome {
        guard !candidateBranches.isEmpty else {
            return WorkspacePullRequestBranchLookupOutcome(
                cacheEntry: baseEntry,
                transientBranches: []
            )
        }

        let branchResults = await withTaskGroup(
            of: (String, WorkspacePullRequestBranchFetchResult).self,
            returning: [(String, WorkspacePullRequestBranchFetchResult)].self
        ) { group in
            for branch in candidateBranches {
                group.addTask {
                    let result = await self.branchFetchResult(
                        repoSlug: repoSlug,
                        branch: branch,
                        session: session,
                        authHeader: authHeader
                    )
                    return (branch, result)
                }
            }

            var collected: [(String, WorkspacePullRequestBranchFetchResult)] = []
            for await result in group {
                collected.append(result)
            }
            return collected
        }

        // Branch-lookup PRs can be outside the recent REST window, so the
        // window-wide GraphQL fetch never covered them. Fetch their CI rollups
        // in one batched call so their sidebar badges reflect real status
        // instead of defaulting to `.neutral`. (`pullRequestCheckStatuses`
        // skips the network when there are no open PRs to query.)
        let foundPullRequests: [GitHubPullRequestProbeItem] = branchResults.compactMap { entry in
            guard case .found(let pullRequest) = entry.1 else { return nil }
            return pullRequest
        }
        let lookupCheckStatuses = await pullRequestCheckStatuses(
            repoSlug: repoSlug,
            pullRequests: foundPullRequests,
            authHeader: authHeader
        )
        return Self.foldingBranchLookupResults(
            branchResults,
            fetchedCheckStatuses: lookupCheckStatuses,
            into: baseEntry,
            refreshedAt: refreshedAt
        )
    }

    /// Folds per-branch lookup results into a refreshed cache entry, applying a
    /// CI rollup to each found PR — preferring a freshly fetched status and
    /// falling back to one already cached in `baseEntry`.
    nonisolated static func foldingBranchLookupResults(
        _ branchResults: [(String, WorkspacePullRequestBranchFetchResult)],
        fetchedCheckStatuses: [Int: PullRequestCheckStatus],
        into baseEntry: WorkspacePullRequestRepoCacheEntry,
        refreshedAt: Date
    ) -> WorkspacePullRequestBranchLookupOutcome {
        var pullRequestsByBranch = baseEntry.pullRequestsByBranch
        var knownAbsentBranches = baseEntry.knownAbsentBranches
        var transientBranches: Set<String> = []

        for (branch, result) in branchResults {
            switch result {
            case .found(let pullRequest):
                let ciStatus = fetchedCheckStatuses[pullRequest.number]
                    ?? Self.cachedCheckStatus(
                        for: pullRequest,
                        normalizedBranch: branch,
                        in: baseEntry
                    )
                pullRequestsByBranch[branch] = ciStatus.map {
                    Self.applyingCheckStatus($0, to: pullRequest)
                } ?? pullRequest
                knownAbsentBranches.remove(branch)
            case .notFound:
                knownAbsentBranches.insert(branch)
            case .transientFailure:
                transientBranches.insert(branch)
            }
        }

        return WorkspacePullRequestBranchLookupOutcome(
            cacheEntry: WorkspacePullRequestRepoCacheEntry(
                fetchedAt: refreshedAt,
                pullRequestsByBranch: pullRequestsByBranch,
                knownAbsentBranches: knownAbsentBranches
            ),
            transientBranches: transientBranches
        )
    }

    /// Looks up the preferred PR for one branch via the `head=` filter.
    nonisolated func branchFetchResult(
        repoSlug: String,
        branch: String,
        session: URLSession,
        authHeader: String?
    ) async -> WorkspacePullRequestBranchFetchResult {
        guard let endpoint = Self.branchEndpoint(
            repoSlug: repoSlug,
            branch: branch
        ) else {
            return .transientFailure
        }

        guard let response = await performRequest(
            session: session,
            endpoint: endpoint,
            authHeader: authHeader
        ) else {
            debugLog("workspace.prRefresh.branch.fail repo=\(repoSlug) branch=\(branch) status=nil")
            return .transientFailure
        }

        guard response.statusCode == 200,
              let pullRequests = Self.decodeJSON([WorkspacePullRequestRESTItem].self, from: response.data) else {
            debugLog(
                "workspace.prRefresh.branch.fail repo=\(repoSlug) " +
                "branch=\(branch) status=\(response.statusCode)"
            )
            return .transientFailure
        }

        let matchingPullRequests = pullRequests
            .map(Self.probeItem)
            .filter { GitMetadataService.normalizedBranchName($0.headRefName) == branch }
        if let preferredPullRequest = Self.preferredPullRequest(from: matchingPullRequests) {
            return .found(preferredPullRequest)
        }
        return .notFound
    }

    /// Builds the `pulls?head=owner:branch` endpoint, or `nil` for a malformed
    /// slug or unencodable query.
    nonisolated static func branchEndpoint(
        repoSlug: String,
        branch: String
    ) -> String? {
        let components = repoSlug.split(separator: "/", maxSplits: 1).map(String.init)
        guard components.count == 2,
              !components[0].isEmpty,
              !components[1].isEmpty else {
            return nil
        }

        var query = URLComponents()
        query.queryItems = [
            URLQueryItem(name: "state", value: "all"),
            URLQueryItem(name: "head", value: "\(components[0]):\(branch)"),
            URLQueryItem(name: "sort", value: "updated"),
            URLQueryItem(name: "direction", value: "desc"),
            URLQueryItem(name: "per_page", value: String(Self.repoPageSize)),
        ]
        guard let percentEncodedQuery = query.percentEncodedQuery else {
            return nil
        }
        return "repos/\(repoSlug)/pulls?\(percentEncodedQuery)"
    }

    /// Maps a REST payload item to a probe item, synthesizing `"MERGED"` state
    /// from a non-empty `mergedAt`.
    nonisolated static func probeItem(
        from pullRequest: WorkspacePullRequestRESTItem
    ) -> GitHubPullRequestProbeItem {
        let rawState = pullRequest.mergedAt?.isEmpty == false ? "MERGED" : pullRequest.state
        return GitHubPullRequestProbeItem(
            number: pullRequest.number,
            state: rawState,
            url: pullRequest.htmlURL,
            updatedAt: pullRequest.updatedAt,
            mergedAt: pullRequest.mergedAt,
            headRefName: pullRequest.head.ref,
            baseRefName: pullRequest.base?.ref
        )
    }

    /// One GET against the GitHub API; `nil` on any transport error.
    nonisolated func performRequest(
        session: URLSession,
        endpoint: String,
        authHeader: String?
    ) async -> WorkspacePullRequestHTTPResponse? {
        guard let url = URL(string: "https://api.github.com/\(endpoint)") else {
            return nil
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("cmux-workspace-pr-poller", forHTTPHeaderField: "User-Agent")
        if let authHeader, !authHeader.isEmpty {
            request.setValue(authHeader, forHTTPHeaderField: "Authorization")
        }

        do {
            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                return nil
            }
            return WorkspacePullRequestHTTPResponse(
                statusCode: httpResponse.statusCode,
                data: data
            )
        } catch {
            return nil
        }
    }

    /// Resolves the API auth header: `GH_TOKEN`/`GITHUB_TOKEN` from the
    /// environment, else `gh auth token` via the injected runner, else `nil`
    /// (unauthenticated requests).
    nonisolated func authHeaderValue() async -> String? {
        let environment = ProcessInfo.processInfo.environment
        if let envToken = environment["GH_TOKEN"] ?? environment["GITHUB_TOKEN"] {
            let trimmed = envToken.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return "Bearer \(trimmed)"
            }
        }

        let directory = FileManager.default.currentDirectoryPath
        let token = await commandRunner.runStandardOutput(
            directory: directory,
            executable: "gh",
            arguments: ["auth", "token"],
            timeout: Self.probeTimeout
        )?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !token.isEmpty else { return nil }
        return "Bearer \(token)"
    }
}
