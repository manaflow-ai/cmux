import AppKit
import CmuxNextCompat
import Foundation

/// The pull request of a folder's checked-out branch, found through acpmux (``AgentPaneGitHub``)
/// rather than `gh pr view`, so the review threads and Create PR work with no `gh` login: the
/// repository is the one `gh` would pick (a remote marked `gh-resolved = base`, else `upstream`,
/// `github`, `origin`, else the first), and the head is the branch on its push remote.
extension AgentPaneGitPullRequest {
    /// The branch's pull request as GitHub answers it (REST `pulls`): open or not.
    nonisolated struct BranchPullRequest: Equatable, Sendable {
        var url: String
        var number: Int
        var open: Bool
        var head: String?
    }

    /// Where the branch's pull request lives and is looked up.
    struct BranchPlace: Equatable {
        /// `owner/name` of the base repository.
        var repository: String
        var branch: String
        /// `owner:branch` as GitHub's `head` filter names it.
        var head: String
    }

    /// The base repository and head of `folder`'s branch; nil when it is not a GitHub checkout on a branch.
    static func branchPlace(git: (_ arguments: [String]) async -> AgentPaneGitProcess.Outcome) async -> BranchPlace? {
        let symbolic = await git(["symbolic-ref", "--quiet", "--short", "HEAD"])
        let branch = symbolic.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard symbolic.status == 0, !branch.isEmpty else { return nil }
        let listed = await git(["remote"])
        // main-actor-ok: `git remote` lists the checkout's remote names, a handful of short lines.
        let remotes = listed.text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        var base: String?
        for remote in remotes {
            if await configValue("remote.\(remote).gh-resolved", git: git) == "base" {
                base = remote
                break
            }
        }
        let chosen = base ?? ["upstream", "github", "origin"].first(where: remotes.contains) ?? remotes.first
        guard let chosen, let repository = await repository(of: chosen, git: git) else { return nil }
        let pushRemote = await configuredPushRemote(branch: branch, git: git)
        let headRepository = pushRemote.isEmpty ? repository : await self.repository(of: pushRemote, git: git) ?? repository
        let trackingRemote = await configValue("branch.\(branch).remote", git: git)
        let trackingMerge = await configValue("branch.\(branch).merge", git: git)
            .flatMap { $0.hasPrefix("refs/heads/") ? String($0.dropFirst("refs/heads/".count)) : nil }
        let destination = !pushRemote.isEmpty && trackingRemote == pushRemote ? (trackingMerge ?? branch) : branch
        let owner = headRepository.split(separator: "/").first.map(String.init) ?? ""
        return BranchPlace(repository: repository, branch: branch, head: "\(owner):\(destination)")
    }

    private static func repository(of remote: String, git: (_ arguments: [String]) async -> AgentPaneGitProcess.Outcome) async -> String? {
        let url = await git(["remote", "get-url", remote])
        return url.status == 0 ? AgentPaneGitHubRepository.parse(url.text) : nil
    }

    /// The pull request whose head is `place`'s branch: the open one, else the latest; nil for none.
    static func branchPullRequest(_ place: BranchPlace, github: GitHubCall) async -> Result<BranchPullRequest?, MergeRefusal> {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._/")
        let parts = place.head.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2, let owner = parts[0].addingPercentEncoding(withAllowedCharacters: allowed),
              let branch = parts[1].addingPercentEncoding(withAllowedCharacters: allowed) else {
            return .failure(MergeRefusal(message: mergeChangedMessage))
        }
        let head = "\(owner):\(branch)"
        let answer = await github(["op": "get", "repo": place.repository, "path": "pulls?head=\(head)&state=all&per_page=20"])
        guard answer.ok, let pulls = await branchPullRequests(answer.body) else {
            return .failure(MergeRefusal(message: answer.refusal))
        }
        return .success(pulls.first(where: \.open) ?? pulls.first)
    }

    /// GitHub's `pulls` list body (up to 20 pulls of unbounded size), parsed off the main actor.
    @concurrent nonisolated private static func branchPullRequests(_ body: Data) async -> [BranchPullRequest]? {
        guard let list = try? JSONSerialization.jsonObject(with: body) as? [[String: Any]] else { return nil }
        return list.compactMap { pull -> BranchPullRequest? in
            guard let url = pull["html_url"] as? String, isPullRequestURL(url), let number = pull["number"] as? Int else { return nil }
            return BranchPullRequest(url: url, number: number, open: (pull["state"] as? String)?.lowercased() == "open",
                                     head: (pull["head"] as? [String: Any])?["sha"] as? String)
        }
    }

    /// Create PR with no `gh` here: the branch's open pull request, else GitHub's compare form for
    /// it, opened in the browser (what `gh pr create --web` opens).
    static func openWithoutCLI(branch: String, base target: String?, github: GitHubCall,
                               git: @escaping (_ arguments: [String]) async -> AgentPaneGitProcess.Outcome) async -> Outcome {
        guard let place = await branchPlace(git: git) else { return .refused(mergeChangedMessage) }
        switch await branchPullRequest(place, github: github) {
        case .failure(let refusal): return .refused(refusal.message)
        case .success(let pull?) where pull.open: return .opened(url: pull.url, number: pull.number)
        case .success: break
        }
        let repo = await github(["op": "get", "repo": place.repository, "path": ""])
        guard let object = repo.object, let url = object["html_url"] as? String, let defaultBranch = object["default_branch"] as? String,
              let shaped = try? JSONSerialization.data(withJSONObject: ["url": url, "defaultBranchRef": ["name": defaultBranch]]), // main-actor-ok: two keys
              let form = await formURL(branch: branch, base: target, repo: String(decoding: shaped, as: UTF8.self), git: git),
              let link = URL(string: form) else {
            return .refused(repo.ok ? mergeChangedMessage : repo.refusal)
        }
        guard await openInBrowser(link) else { return .opened(url: form, number: nil) }
        return .formOpened(url: form)
    }

    /// Opens `link` off the main thread; whether it opened.
    @MainActor private static func openInBrowser(_ link: URL) async -> Bool {
        await withCheckedContinuation { done in NSWorkspace.shared.openInBackground(link) { done.resume(returning: $0) } }
    }
}
