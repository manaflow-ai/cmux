import CryptoKit
import Foundation

extension PullRequestProbeService {
    /// Fetches GitHub’s PR commit rollup through the shared authenticated transport.
    /// Reruns replace earlier attempts within the same provider/workflow/event.
#if compiler(>=6.2)
    @concurrent
#endif
    /// Runs optional checks work with caller-controlled cache reuse.
    public nonisolated func fetchPullRequestChecks(
        repoSlug: String,
        pullRequestNumber: Int,
        headSHA: String?,
        allowCachedResults: Bool = true
    ) async -> PullRequestChecksSummary? {
        guard !Task.isCancelled, pullRequestNumber > 0,
              let headSHA, !headSHA.isEmpty,
              GitMetadataService.normalizedGitHubRepositorySlug(repoSlug) == repoSlug,
              let authHeader = await authHeaderValue() else { return nil }
        let identity = Data(SHA256.hash(data: Data(authHeader.utf8))).base64EncodedString()
        let key = "\(identity)|\(repoSlug)#\(pullRequestNumber)|\(headSHA)"
        if allowCachedResults, let cached = await checksCache.value(for: key, now: Date()) { return cached }
        let slug = repoSlug.split(separator: "/")
        guard slug.count == 2 else { return nil }
        var currentSHA: String?
        var mergeStatus: PullRequestMergeStatus = .unknown
        var contexts: [PullRequestCheckIdentity: PullRequestCheckContext] = [:]
        var ambiguousIdentities: Set<PullRequestCheckIdentity> = []
        var cursor: String?
        var seenCursors: Set<String> = []
        var complete = false
        for _ in 0..<10 {
            guard !Task.isCancelled else { return nil }
            let query = PullRequestChecksQuery(owner: String(slug[0]), repository: String(slug[1]), number: pullRequestNumber, cursor: cursor)
            guard let body = try? query.encodedBody(),
                  let response = await requestCoordinator.response(endpoint: "graphql", authHeader: authHeader, body: body),
                  response.statusCode == 200,
                  let page = PullRequestChecksPage(data: response.data) else { break }
            // A push between pages invalidates this collection, even when all
            // fetched pages happened to contain passing checks.
            guard page.headSHA == headSHA else {
                await checksCache.invalidate(key)
                return nil
            }
            if let currentSHA, currentSHA != page.headSHA { return nil }
            currentSHA = page.headSHA
            mergeStatus = page.mergeStatus
            for context in page.contexts {
                if ambiguousIdentities.contains(context.identity) { continue }
                if let previous = contexts[context.identity] {
                    switch previous.ordering(against: context) {
                    case .newer:
                        continue
                    case .older:
                        break
                    case .ambiguous:
                        ambiguousIdentities.insert(context.identity)
                        let unavailable = PullRequestCheck(
                            id: context.check.id,
                            name: context.check.name,
                            status: .unavailable,
                            detailsURL: context.check.detailsURL
                        )
                        contexts[context.identity] = PullRequestCheckContext(
                            check: unavailable,
                            identity: context.identity,
                            startedAt: "",
                            runNumber: nil
                        )
                        continue
                    }
                }
                contexts[context.identity] = context
            }
            guard let next = page.nextCursor else { complete = true; break }
            guard seenCursors.insert(next).inserted else { break }
            cursor = next
        }
        guard !Task.isCancelled else { return nil }
        let collectedChecks: [PullRequestCheck] = contexts.values.map { context in
            context.check
        }
        let checks = collectedChecks.sorted { lhs, rhs in
            if lhs.name == rhs.name {
                return lhs.id < rhs.id
            }
            return lhs.name < rhs.name
        }
        let summary = PullRequestChecksSummary(checks: checks, mergeStatus: mergeStatus, complete: complete)
        if complete, summary.status != PullRequestCheckStatus.unavailable, currentSHA == headSHA {
            await checksCache.insert(summary, for: key, now: Date())
        }
        return summary
    }
}
