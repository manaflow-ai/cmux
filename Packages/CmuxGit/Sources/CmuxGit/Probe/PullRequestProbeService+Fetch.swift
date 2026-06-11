public import Foundation

extension PullRequestProbeService {
    // MARK: Stage 2 — repository fetch

    /// Fetches pull-request data for every repository the candidates need.
    ///
    /// Repositories are fetched concurrently. A repository whose cached entry is
    /// fresh (younger than ``repoCacheLifetime``) and already covers every
    /// candidate branch is served from cache when `allowCachedResults` permits;
    /// otherwise the recent-PRs pages are fetched and any still-unresolved
    /// branches get targeted per-branch lookups. Non-dot-com hosts without a
    /// token are skipped before any HTTP request is issued.
    ///
    /// - Parameters:
    ///   - repoDirectoriesByReference: Repositories to fetch (reference →
    ///     representative directory).
    ///   - candidateBranchesByRepo: The branches each repository must resolve.
    ///   - cacheByReference: The caller-owned repo cache.
    ///   - now: The refresh timestamp used for cache-freshness checks.
    ///   - allowCachedResults: Whether fresh cache entries may satisfy the fetch.
    /// - Returns: One ``WorkspacePullRequestRepoFetchResult`` per attempted
    ///   repository reference.
    public nonisolated func fetchRepoResults(
        repoDirectoriesByReference: [GitHubRepositoryReference: String],
        candidateBranchesByRepo: [GitHubRepositoryReference: Set<String>],
        cacheByReference: [GitHubRepositoryReference: WorkspacePullRequestRepoCacheEntry],
        now: Date,
        allowCachedResults: Bool
    ) async -> [GitHubRepositoryReference: WorkspacePullRequestRepoFetchResult] {
        guard !repoDirectoriesByReference.isEmpty else { return [:] }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = max(Self.probeTimeout, 8)
        configuration.timeoutIntervalForResource = max(Self.probeTimeout, 8)
        let session = URLSession(configuration: configuration)
        let tokensByHost = await authTokensByHost(
            for: Set(repoDirectoriesByReference.keys.map(\.host))
        )
        var results: [GitHubRepositoryReference: WorkspacePullRequestRepoFetchResult] = [:]

        let fetchedResults = await withTaskGroup(
            of: (GitHubRepositoryReference, WorkspacePullRequestRepoFetchResult).self,
            returning: [(GitHubRepositoryReference, WorkspacePullRequestRepoFetchResult)].self
        ) { group in
            for reference in repoDirectoriesByReference.keys {
                let token = tokensByHost[reference.host]
                guard reference.host.isPollable(token: token) else {
                    debugLog("workspace.prRefresh.repo.skip repo=\(reference.hostQualifiedSlug) reason=no-token")
                    continue
                }

                let authHeader = token.map { "Bearer \($0)" }
                group.addTask {
                    let result = await self.repoFetchResult(
                        reference: reference,
                        candidateBranches: candidateBranchesByRepo[reference] ?? [],
                        cachedEntry: cacheByReference[reference],
                        useCachedRecentWindow: allowCachedResults
                            && (cacheByReference[reference].map {
                                now.timeIntervalSince($0.fetchedAt) < Self.repoCacheLifetime
                            } ?? false),
                        session: session,
                        authHeader: authHeader
                    )
                    return (reference, result)
                }
            }

            var collected: [(GitHubRepositoryReference, WorkspacePullRequestRepoFetchResult)] = []
            for await result in group {
                collected.append(result)
            }
            return collected
        }

        for (reference, result) in fetchedResults {
            results[reference] = result
        }
        return results
    }

    /// Fetches one repository: serve from cache when permitted and complete,
    /// else page the recent PRs and per-branch-look-up any leftover branches.
    nonisolated func repoFetchResult(
        reference: GitHubRepositoryReference,
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
                    "workspace.prRefresh.repo.cache repo=\(reference.hostQualifiedSlug) " +
                    "branches=\(cachedEntry.pullRequestsByBranch.count)"
                )
                return .success(cachedEntry, usedCache: true, transientBranches: [])
            }

            let lookupOutcome = await branchLookupOutcome(
                reference: reference,
                candidateBranches: unresolvedBranches,
                baseEntry: cachedEntry,
                refreshedAt: Date(),
                session: session,
                authHeader: authHeader
            )
            debugLog(
                "workspace.prRefresh.repo.cache.miss repo=\(reference.hostQualifiedSlug) " +
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
            let endpoint = "repos/\(reference.slug)/pulls?state=all&sort=updated&direction=desc&per_page=\(Self.repoPageSize)&page=\(page)"
            guard let response = await performRequest(
                host: reference.host,
                session: session,
                endpoint: endpoint,
                authHeader: authHeader
            ) else {
                debugLog("workspace.prRefresh.repo.fail repo=\(reference.hostQualifiedSlug) page=\(page) status=nil")
                return .transientFailure
            }

            guard response.statusCode == 200,
                  let pullRequests = Self.decodeJSON([WorkspacePullRequestRESTItem].self, from: response.data) else {
                debugLog("workspace.prRefresh.repo.fail repo=\(reference.hostQualifiedSlug) page=\(page) status=\(response.statusCode)")
                return .transientFailure
            }

            fetchedPageCount += 1
            allPullRequests.append(contentsOf: pullRequests.map(Self.probeItem))
            if pullRequests.count < Self.repoPageSize {
                break
            }
            page += 1
        }

        let recentWindowEntry = WorkspacePullRequestRepoCacheEntry(
            fetchedAt: fetchTimestamp,
            pullRequestsByBranch: Self.pullRequestMapByNormalizedBranch(from: allPullRequests)
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
                reference: reference,
                candidateBranches: unresolvedBranches,
                baseEntry: recentWindowEntry,
                refreshedAt: fetchTimestamp,
                session: session,
                authHeader: authHeader
            )
        }
        debugLog(
            "workspace.prRefresh.repo.success repo=\(reference.hostQualifiedSlug) pages=\(fetchedPageCount) " +
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
        reference: GitHubRepositoryReference,
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
                        reference: reference,
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

        var pullRequestsByBranch = baseEntry.pullRequestsByBranch
        var knownAbsentBranches = baseEntry.knownAbsentBranches
        var transientBranches: Set<String> = []

        for (branch, result) in branchResults {
            switch result {
            case .found(let pullRequest):
                pullRequestsByBranch[branch] = pullRequest
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
        reference: GitHubRepositoryReference,
        branch: String,
        session: URLSession,
        authHeader: String?
    ) async -> WorkspacePullRequestBranchFetchResult {
        guard let endpoint = Self.branchEndpoint(
            reference: reference,
            branch: branch
        ) else {
            return .transientFailure
        }

        guard let response = await performRequest(
            host: reference.host,
            session: session,
            endpoint: endpoint,
            authHeader: authHeader
        ) else {
            debugLog("workspace.prRefresh.branch.fail repo=\(reference.hostQualifiedSlug) branch=\(branch) status=nil")
            return .transientFailure
        }

        guard response.statusCode == 200,
              let pullRequests = Self.decodeJSON([WorkspacePullRequestRESTItem].self, from: response.data) else {
            debugLog(
                "workspace.prRefresh.branch.fail repo=\(reference.hostQualifiedSlug) " +
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
    /// reference or unencodable query.
    nonisolated static func branchEndpoint(
        reference: GitHubRepositoryReference,
        branch: String
    ) -> String? {
        guard !reference.owner.isEmpty,
              !reference.repo.isEmpty else {
            return nil
        }

        var query = URLComponents()
        query.queryItems = [
            URLQueryItem(name: "state", value: "all"),
            URLQueryItem(name: "head", value: "\(reference.owner):\(branch)"),
            URLQueryItem(name: "sort", value: "updated"),
            URLQueryItem(name: "direction", value: "desc"),
            URLQueryItem(name: "per_page", value: String(Self.repoPageSize)),
        ]
        guard let percentEncodedQuery = query.percentEncodedQuery else {
            return nil
        }
        return "repos/\(reference.slug)/pulls?\(percentEncodedQuery)"
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
        host: GitHubHost,
        session: URLSession,
        endpoint: String,
        authHeader: String?
    ) async -> WorkspacePullRequestHTTPResponse? {
        guard let url = host.apiURL(endpoint: endpoint) else {
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

    /// Resolves auth tokens for all hosts needed in the current fetch.
    ///
    /// Because remote parsing now accepts any host, a crafted repo config could
    /// carry many distinct remote hosts. The probe count is capped (``github.com``
    /// is always probed first) and concurrency is bounded so the hot sidebar poll
    /// path cannot fork an unbounded number of `gh` child processes.
    nonisolated func authTokensByHost(for hosts: Set<GitHubHost>) async -> [GitHubHost: String] {
        let orderedHosts = hosts.sorted {
            if $0.isDotCom != $1.isDotCom { return $0.isDotCom }
            return $0.authority < $1.authority
        }
        let probeHosts = Array(orderedHosts.prefix(Self.maxTokenProbeHosts))
        if probeHosts.count < orderedHosts.count {
            debugLog("workspace.prRefresh.token.truncate probed=\(probeHosts.count) total=\(orderedHosts.count)")
        }

        return await withTaskGroup(
            of: (GitHubHost, String?).self,
            returning: [GitHubHost: String].self
        ) { group in
            var collected: [GitHubHost: String] = [:]
            var nextIndex = 0

            func addProbe() {
                guard nextIndex < probeHosts.count else { return }
                let host = probeHosts[nextIndex]
                nextIndex += 1
                group.addTask {
                    (host, await self.authToken(for: host))
                }
            }

            for _ in 0..<min(Self.maxConcurrentTokenProbes, probeHosts.count) {
                addProbe()
            }

            while let (host, token) = await group.next() {
                if let token {
                    collected[host] = token
                }
                addProbe()
            }
            return collected
        }
    }

    /// Resolves the API auth token for `host`, or `nil` when none is available.
    ///
    /// For `github.com`, `GH_TOKEN`/`GITHUB_TOKEN` is preferred, falling back to
    /// `gh`. For every other host the token comes from
    /// `gh auth token --hostname <host>`, but any ambient token env var is
    /// refused: `gh` hands `GH_ENTERPRISE_TOKEN`/`GITHUB_ENTERPRISE_TOKEN` to any
    /// enterprise host and `GH_TOKEN`/`GITHUB_TOKEN` to `*.ghe.com` hosts, so a
    /// remote pointing at an unverified host would otherwise be sent the user's
    /// ambient credential. Only a per-host stored credential (from
    /// `gh auth login --hostname`) — which differs from every ambient env token —
    /// is trusted for non-`github.com` hosts.
    nonisolated func authToken(for host: GitHubHost) async -> String? {
        if host.isDotCom,
           let envToken = environment["GH_TOKEN"] ?? environment["GITHUB_TOKEN"] {
            let trimmed = envToken.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return trimmed
            }
        }

        let directory = FileManager.default.currentDirectoryPath
        let resolved = await host.authToken { executable, arguments in
            await commandRunner.runStandardOutput(
                directory: directory,
                executable: executable,
                arguments: arguments,
                timeout: Self.probeTimeout
            )
        }

        if let resolved, !host.isDotCom, ambientTokens.contains(resolved) {
            debugLog("workspace.prRefresh.token.reject host=\(host.hostname) reason=ambient-token")
            return nil
        }
        return resolved
    }

    /// The non-empty ambient token env values that `gh` would hand back for a
    /// non-`github.com` host (`GH_TOKEN`/`GITHUB_TOKEN` for `*.ghe.com`,
    /// `GH_ENTERPRISE_TOKEN`/`GITHUB_ENTERPRISE_TOKEN` for enterprise hosts);
    /// matching tokens are not trusted for an unverified host.
    private var ambientTokens: Set<String> {
        Set(
            ["GH_TOKEN", "GITHUB_TOKEN", "GH_ENTERPRISE_TOKEN", "GITHUB_ENTERPRISE_TOKEN"]
                .compactMap { environment[$0]?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        )
    }
}
