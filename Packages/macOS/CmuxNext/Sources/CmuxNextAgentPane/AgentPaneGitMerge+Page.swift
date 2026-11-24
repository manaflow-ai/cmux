public import Foundation

/// The GitHub page's Merge and its reads (CmuxNextGitHubViewer): the page shows one pull request by
/// its link, with no checkout of its branch on this Mac, so its merge is pinned to the head the page
/// showed rather than to this Mac's HEAD (the PR chip's merge, AgentPaneGitMerge.swift). It is the
/// normal merge path: GitHub's merge API pinned to `<head>` (`sha`), with the repository's default
/// method for the viewer, never an override. GitHub's own rules (required checks and reviews, a merge
/// queue) still decide; this refuses only what GitHub itself says cannot merge now.
public extension AgentPaneGitPullRequest {
    /// What the page's Merge did.
    nonisolated enum PageMerge: Equatable, Sendable {
        /// Merged, or taken into the base branch's merge queue (`queued`).
        case merged(queued: Bool)
        case refused(String)
    }

    /// Merges the pull request at `url` (an https pull request address) when GitHub still has it
    /// at `head`, the commit the page showed; nothing is pushed and no branch is deleted. It runs
    /// through acpmux (``AgentPaneGitHub``): the cmux GitHub App's token, or the person's `gh`.
    @concurrent static func mergeShown(url: String, head: String) async -> PageMerge {
        guard isPullRequestURL(url), isCommit(head), let pull = AgentPaneGitHubREST.pullRequest(url) else { return .refused(mergeChangedMessage) }
        let view: MergeView
        switch await mergeView(pull.repository, pull.number) {
        case .failure(let refusal): return .refused(refusal.message)
        case .success(let read): view = read
        }
        if let refusal = pageMergeRefusal(view.pullRequest, url: url, head: head) { return .refused(refusal) }
        return await mergePinned(pull.repository, pull.number, head: head, method: view.method)
    }

    /// Why `view` (``mergeView(_:_:)``'s pull request) cannot merge at `head` now, nil when it
    /// can: it must be the pull request at `url`, open, not a draft, still at `head`, and GitHub's
    /// merge state must not say it is blocked, behind, conflicting or not worked out yet. A red
    /// check GitHub does not require (`UNSTABLE`) merges, as GitHub's own button lets it.
    nonisolated static func pageMergeRefusal(_ view: [String: Any], url: String, head: String) -> String? {
        guard view["url"] as? String == url else { return mergeChangedMessage }
        guard (view["state"] as? String)?.uppercased() == "OPEN" else { return mergeNotOpenMessage }
        guard view["isDraft"] as? Bool != true else { return mergeNotReadyMessage }
        guard let current = view["headRefOid"] as? String, current.lowercased() == head.lowercased() else { return mergeChangedMessage }
        switch (view["mergeStateStatus"] as? String)?.uppercased() {
        case "CLEAN", "HAS_HOOKS", "UNSTABLE": return nil
        case "BEHIND": return mergeBehindMessage
        case "UNKNOWN", nil: return mergeUnknownMessage
        default: return mergeNotReadyMessage
        }
    }

    /// A full commit id (SHA-1 or SHA-256).
    nonisolated static func isCommit(_ text: String) -> Bool {
        (text.count == 40 || text.count == 64) && text.allSatisfy(\.isHexDigit)
    }

    /// Re-runs the failed jobs of the Actions run `run` in `repository` (`owner/name`) through
    /// GitHub's re-run-failed-jobs API; nil when GitHub took it, else its reason.
    @concurrent static func rerunFailed(repository: String, run: Int) async -> String? {
        let parts = repository.split(separator: "/").map(String.init)
        guard run > 0, parts.count == 2,
              parts.allSatisfy({ !$0.hasPrefix("-") && $0.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "-._".contains($0)) } }) else {
            return mergeChangedMessage
        }
        let answer = await AgentPaneGitHubREST.call(["op": "run.rerunFailed", "repo": repository, "run": run])
        return answer.ok ? nil : answer.refusal
    }

    /// A read-only GraphQL query's answer for the page's reads beyond the card's fields (a pull
    /// request's body and conversation, its checks), through acpmux; nil when it did not work.
    @concurrent static func pageRead(_ repository: String, query: String, variables: [String: any Sendable],
                                     scope: String = "pulls") async -> Data? {
        let answer = await AgentPaneGitHubREST.graphql(repository, query, variables, scope: scope)
        return answer.ok ? answer.body : nil
    }

    /// `GET repos/{repository}/{path}` for the page (an Actions job, its log's last `tail` bytes),
    /// through acpmux; nil when it did not work.
    @concurrent static func pageGet(_ repository: String, _ path: String, tail: Int? = nil) async -> Data? {
        let answer = await AgentPaneGitHubREST.get(repository, path, tail: tail)
        return answer.ok ? answer.body : nil
    }
}
