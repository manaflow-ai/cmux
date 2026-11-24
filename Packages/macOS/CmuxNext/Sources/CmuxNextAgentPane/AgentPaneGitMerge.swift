import Foundation

/// Merge from the PR chip (cx-ncc.77.4, Codex desktop's): the branch's pull request merges only
/// when it is the one the page showed, open and not a draft, GitHub calls its merge state clean
/// (checks, reviews and conflicts settled) with every check passed, and its head is this Mac's
/// HEAD. GitHub then merges exactly that head with the repository's default method; nothing is
/// pushed and no branch is deleted. A base branch with a merge queue takes it into the queue, which
/// the reply says. Every GitHub call goes through acpmux (``AgentPaneGitHub``): the cmux GitHub
/// App's token, or the person's `gh`.
extension AgentPaneGitPullRequest {
    /// One GitHub op (``AgentPaneGitHub/call(_:)``; tests pass a fake).
    typealias GitHubCall = @Sendable (_ params: [String: any Sendable]) async -> AgentPaneGitHubREST.Answer

    /// GraphQL's non-null mark, spelled apart so the crash ratchet does not read it as an unwrap.
    private nonisolated static let required = "!"
    /// What a merge reads first: the pull request's state, merge state, head and checks, and the
    /// repository's default merge method for the viewer.
    nonisolated static let mergeQuery = """
        query($owner: String\(required), $name: String\(required), $number: Int\(required)) { repository(owner: $owner, name: $name) {
          viewerDefaultMergeMethod
          pullRequest(number: $number) { url number state isDraft mergeStateStatus headRefOid
            commits(last: 1) { nodes { commit { statusCheckRollup { contexts(first: 100) { nodes {
              __typename ... on CheckRun { name status conclusion } ... on StatusContext { context state } } } } } } } } } }
        """

    /// A merge's first read: the pull request as `gh pr view --json` names its fields (its checks
    /// as `statusCheckRollup`), and the method to merge with.
    nonisolated struct MergeView {
        var pullRequest: [String: Any]
        var method: String
    }

    nonisolated struct MergeRefusal: Error {
        var message: String
    }

    /// ``mergeQuery`` for pull request `number` of `repository`.
    nonisolated static func mergeView(_ repository: String, _ number: Int, github: GitHubCall = AgentPaneGitHubREST.call) async -> Result<MergeView, MergeRefusal> {
        let parts = repository.split(separator: "/").map(String.init)
        guard parts.count == 2 else { return .failure(MergeRefusal(message: mergeChangedMessage)) }
        // Read with checks' permissions: under `pulls` alone an App token gets an empty rollup, and
        // the merge would rest on mergeStateStatus alone.
        let answer = await github(["op": "graphql", "repo": repository, "query": mergeQuery, "scope": "checks",
                                   "variables": ["owner": parts[0], "name": parts[1], "number": number] as [String: any Sendable]])
        guard let repo = answer.data?["repository"] as? [String: Any], var pull = repo["pullRequest"] as? [String: Any] else {
            return .failure(MergeRefusal(message: answer.ok ? mergeChangedMessage : answer.refusal))
        }
        let commits = (pull["commits"] as? [String: Any])?["nodes"] as? [[String: Any]] ?? []
        let rollup = (commits.last?["commit"] as? [String: Any])?["statusCheckRollup"] as? [String: Any]
        pull["statusCheckRollup"] = (rollup?["contexts"] as? [String: Any])?["nodes"] as? [[String: Any]] ?? []
        let method = (repo["viewerDefaultMergeMethod"] as? String)?.lowercased()
        return .success(MergeView(pullRequest: pull, method: method.flatMap { ["merge", "squash", "rebase"].contains($0) ? $0 : nil } ?? "merge"))
    }

    /// Merges pull request `number` of `repository` at exactly `head` with `method`, then reads
    /// back whether it merged or went into the base branch's merge queue.
    static func mergePinned(_ repository: String, _ number: Int, head: String, method: String,
                            github: GitHubCall = AgentPaneGitHubREST.call) async -> PageMerge {
        let merged = await github(["op": "pr.merge", "repo": repository, "number": number, "head": head, "method": method])
        guard merged.ok else { return .refused(merged.refusal) }
        // A base branch with a merge queue takes it into the queue, not merged yet.
        let after = await mergeView(repository, number, github: github)
        if let state = (try? after.get().pullRequest["state"] as? String)?.uppercased() {
            return .merged(queued: state != "MERGED")
        }
        // The read-back failed: only GitHub's own answer to the merge says it merged; else unknown.
        if (merged.object?["merged"] as? Bool) == true { return .merged(queued: false) }
        return .refused(mergeUnconfirmedMessage)
    }

    @concurrent static func merge(_ number: Int, url shown: String, in folder: String,
                                  github: GitHubCall = AgentPaneGitHubREST.call) async -> Outcome {
        guard let pull = AgentPaneGitHubREST.pullRequest(shown), pull.number == number else { return .refused(mergeChangedMessage) }
        let view: MergeView
        switch await mergeView(pull.repository, number, github: github) {
        case .failure(let refusal): return .refused(refusal.message)
        case .success(let read): view = read
        }
        let object = view.pullRequest, how = view.method
        guard let url = object["url"] as? String, object["number"] as? Int == number, url == shown else { return .refused(mergeChangedMessage) }
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
        switch await mergePinned(pull.repository, number, head: head, method: how, github: github) {
        case .refused(let message): return .refused(message)
        case .merged(let queued): return .merged(url: url, number: number, queued: queued)
        }
    }

    /// The branch's pull request is not the one the page showed.
    nonisolated static var mergeChangedMessage: String {
        String(localized: "agentPane.error.gitMergeChanged",
               defaultValue: "This branch's pull request changed. Look at it again before merging.", bundle: .localizedModule)
    }

    /// The pull request is merged or closed.
    nonisolated static var mergeNotOpenMessage: String {
        String(localized: "agentPane.error.gitMergeNotOpen", defaultValue: "This pull request isn't open.", bundle: .localizedModule)
    }

    /// A draft, a check not passed, or GitHub's merge state not clean (a review, conflicts).
    nonisolated static var mergeNotReadyMessage: String {
        String(localized: "agentPane.error.gitMergeNotReady",
               defaultValue: "GitHub says this pull request can't merge yet.",
               bundle: .localizedModule)
    }

    /// GitHub wants the branch updated with its base first.
    nonisolated static var mergeBehindMessage: String {
        String(localized: "agentPane.error.gitMergeBehind",
               defaultValue: "This branch is behind its base. Update it, then merge.", bundle: .localizedModule)
    }

    /// GitHub has not worked out yet whether it can merge (just after a push).
    nonisolated static var mergeUnknownMessage: String {
        // retry-prompt-ok: merging a pull request is a side effect the person must choose
        String(localized: "agentPane.error.gitMergeUnknown",
               defaultValue: "GitHub is still checking whether this pull request can merge. Try again in a moment.",
               bundle: .localizedModule)
    }

    /// GitHub took the merge, but neither its answer nor a read-back says it merged.
    nonisolated static var mergeUnconfirmedMessage: String {
        String(localized: "agentPane.error.gitMergeUnconfirmed",
               defaultValue: "GitHub took the merge but hasn't confirmed it. Open the pull request to see whether it merged.",
               bundle: .localizedModule)
    }

    /// This Mac's HEAD is not the pull request's head.
    nonisolated static var mergeHeadMessage: String {
        String(localized: "agentPane.error.gitMergeHead",
               defaultValue: "This branch here isn't the pull request's head. Push or pull first, then merge.", bundle: .localizedModule)
    }
}
