public import Foundation

/// The GitHub page's Merge and its reads (CmuxNextGitHubViewer): the page shows one pull request by
/// its link, with no checkout of its branch on this Mac, so its merge is pinned to the head the page
/// showed rather than to this Mac's HEAD (the PR chip's merge, AgentPaneGitMerge.swift). It is the
/// normal merge path: `gh pr merge <url> --<method> --match-head-commit <head>`, with the user's
/// default method, never an override. GitHub's own rules (required checks and reviews, a merge
/// queue) still decide; this refuses only what GitHub itself says cannot merge now.
public extension AgentPaneGitPullRequest {
    /// What the page's Merge did.
    nonisolated enum PageMerge: Equatable, Sendable {
        /// Merged, or taken into the base branch's merge queue (`queued`).
        case merged(queued: Bool)
        case refused(String)
    }

    nonisolated static let pageMergeFields = "url,number,state,isDraft,mergeStateStatus,headRefOid"

    /// Merges the pull request at `url` (an https pull request address) when GitHub still has it
    /// at `head`, the commit the page showed; nothing is pushed and no branch is deleted.
    @concurrent static func mergeShown(url: String, head: String) async -> PageMerge {
        guard isPullRequestURL(url), isCommit(head) else { return .refused(mergeChangedMessage) }
        guard let gh = gitHubCLI() else { return .refused(noGitHubCLIMessage) }
        let home = NSHomeDirectory()
        let cli = { (arguments: [String]) in
            await AgentPaneGitProcess.output(arguments, executable: gh, directory: home, timeout: networkTimeout, network: true)
        }
        let view = await cli(["pr", "view", url, "--json", pageMergeFields])
        guard view.status == 0, let object = AgentPaneGitReviewThread.object(in: view.text) else { return .refused(message(view)) }
        if let refusal = pageMergeRefusal(object, url: url, head: head) { return .refused(refusal) }
        let how = await method(gh: gh, in: home, url: url)
        let merged = await cli(["pr", "merge", url, "--\(how)", "--match-head-commit", head])
        guard merged.status == 0 else { return .refused(message(merged)) }
        // A base branch with a merge queue takes it into the queue, not merged yet.
        let after = await cli(["pr", "view", url, "--json", "state"])
        let state = (AgentPaneGitReviewThread.object(in: after.text)?["state"] as? String)?.uppercased()
        return .merged(queued: state != "MERGED")
    }

    /// Why `view` (`gh pr view --json` ``pageMergeFields``) cannot merge at `head` now, nil when it
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
    /// gh's normal path (`gh run rerun <run> --failed`); nil when GitHub took it, else its reason.
    @concurrent static func rerunFailed(repository: String, run: Int) async -> String? {
        let parts = repository.split(separator: "/").map(String.init)
        guard run > 0, parts.count == 2,
              parts.allSatisfy({ !$0.hasPrefix("-") && $0.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "-._".contains($0)) } }) else {
            return mergeChangedMessage
        }
        guard let gh = gitHubCLI() else { return noGitHubCLIMessage }
        let outcome = await AgentPaneGitProcess.output(["run", "rerun", String(run), "--failed", "--repo", repository],
                                                       executable: gh, directory: NSHomeDirectory(), timeout: networkTimeout, network: true)
        return outcome.status == 0 ? nil : message(outcome)
    }

    /// gh's output for `arguments` in the home folder, for the page's reads beyond the card's
    /// fields (a pull request's body and conversation); nil when gh is missing, fails or times out.
    @concurrent static func pageRead(_ arguments: [String]) async -> Data? {
        guard let gh = gitHubCLI() else { return nil }
        let outcome = await AgentPaneGitProcess.output(arguments, executable: gh, directory: NSHomeDirectory(),
                                                       timeout: networkTimeout, network: true)
        guard outcome.status == 0 else { return nil }
        return Data(outcome.text.utf8)
    }
}
