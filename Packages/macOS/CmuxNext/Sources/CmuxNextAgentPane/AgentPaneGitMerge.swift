import Foundation

/// Merge from the PR chip (cx-ncc.77.4, Codex desktop's): the branch's pull request merges only
/// when it is the one the page showed, open and not a draft, GitHub calls its merge state clean
/// (checks, reviews and conflicts settled) with every check passed, and its head is this Mac's
/// HEAD. gh then merges exactly that head with the user's default method; nothing is pushed and no
/// branch is deleted. A base branch with a merge queue takes it into the queue, which the reply says.
extension AgentPaneGitPullRequest {
    static let mergeFields = "url,number,state,isDraft,mergeStateStatus,headRefOid,statusCheckRollup"

    @concurrent static func merge(_ number: Int, url shown: String, in folder: String, gh: String) async -> Outcome {
        let cli = { (arguments: [String]) in
            await AgentPaneGitProcess.output(arguments, executable: gh, directory: folder, timeout: networkTimeout, network: true)
        }
        let view = await cli(["pr", "view", "--json", mergeFields])
        guard view.status == 0, let object = AgentPaneGitReviewThread.object(in: view.text),
              let url = object["url"] as? String, isPullRequestURL(url) else { return .refused(message(view)) }
        guard object["number"] as? Int == number, url == shown else { return .refused(mergeChangedMessage) }
        guard (object["state"] as? String)?.uppercased() == "OPEN" else { return .refused(mergeNotOpenMessage) }
        let rollup = object["statusCheckRollup"] as? [[String: Any]] ?? []
        let checks = AgentPanePullRequest.checks(rollup).state
        let mergeState = (object["mergeStateStatus"] as? String)?.uppercased()
        guard object["isDraft"] as? Bool != true, checks == "passing" || checks == "none" else { return .refused(mergeNotReadyMessage) }
        guard mergeState != "BEHIND" else { return .refused(mergeBehindMessage) }
        guard mergeState != "UNKNOWN" else { return .refused(mergeUnknownMessage) }
        guard ["CLEAN", "HAS_HOOKS"].contains(mergeState) else { return .refused(mergeNotReadyMessage) }
        let local = await AgentPaneGitProcess.output(["-C", folder, "rev-parse", "HEAD"], timeout: localTimeout)
        guard let head = object["headRefOid"] as? String, head.count >= 40, head.allSatisfy(\.isHexDigit),
              local.status == 0, local.text.trimmingCharacters(in: .whitespacesAndNewlines) == head else {
            return .refused(mergeHeadMessage)
        }
        let how = await method(gh: gh, in: folder, url: url)
        // By its url, so gh merges the pull request it just viewed and not another with that number.
        let merged = await cli(["pr", "merge", url, "--\(how)", "--match-head-commit", head])
        guard merged.status == 0 else { return .refused(message(merged)) }
        // A base branch with a merge queue takes it into the queue, not merged yet.
        let after = await cli(["pr", "view", url, "--json", "state"])
        let state = (AgentPaneGitReviewThread.object(in: after.text)?["state"] as? String)?.uppercased()
        return .merged(url: url, number: number, queued: state != "MERGED")
    }

    /// The user's default merge method for the repository (`merge`, `squash` or `rebase`); `merge`
    /// when gh can't say.
    @concurrent private static func method(gh: String, in folder: String, url: String) async -> String {
        let parts = URL(string: url)?.path.split(separator: "/").map(String.init) ?? []
        guard let host = URL(string: url)?.host, parts.count >= 2 else { return "merge" }
        let view = await AgentPaneGitProcess.output(["repo", "view", "\(host)/\(parts[0])/\(parts[1])", "--json", "viewerDefaultMergeMethod"],
                                                    executable: gh, directory: folder, timeout: networkTimeout, network: true)
        let method = (AgentPaneGitReviewThread.object(in: view.text)?["viewerDefaultMergeMethod"] as? String)?.lowercased()
        guard view.status == 0, let method, ["merge", "squash", "rebase"].contains(method) else { return "merge" }
        return method
    }

    /// The branch's pull request is not the one the page showed.
    nonisolated static var mergeChangedMessage: String {
        String(localized: "agentPane.error.gitMergeChanged",
               defaultValue: "This branch's pull request changed. Look at it again before merging.", bundle: .module)
    }

    /// The pull request is merged or closed.
    nonisolated static var mergeNotOpenMessage: String {
        String(localized: "agentPane.error.gitMergeNotOpen", defaultValue: "This pull request isn't open.", bundle: .module)
    }

    /// A draft, a check not passed, or GitHub's merge state not clean (a review, conflicts).
    nonisolated static var mergeNotReadyMessage: String {
        String(localized: "agentPane.error.gitMergeNotReady",
               defaultValue: "GitHub says this pull request isn't ready to merge: a check, a review or a conflict is still open.",
               bundle: .module)
    }

    /// GitHub wants the branch updated with its base first.
    nonisolated static var mergeBehindMessage: String {
        String(localized: "agentPane.error.gitMergeBehind",
               defaultValue: "This branch is behind its base. Update it, then merge.", bundle: .module)
    }

    /// GitHub has not worked out yet whether it can merge (just after a push).
    nonisolated static var mergeUnknownMessage: String {
        String(localized: "agentPane.error.gitMergeUnknown",
               defaultValue: "GitHub is still checking whether this pull request can merge. Try again in a moment.",
               bundle: .module)
    }

    /// This Mac's HEAD is not the pull request's head.
    nonisolated static var mergeHeadMessage: String {
        String(localized: "agentPane.error.gitMergeHead",
               defaultValue: "This branch here isn't the pull request's head. Push or pull first, then merge.", bundle: .module)
    }
}
