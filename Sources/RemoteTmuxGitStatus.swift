import Foundation

/// Git branch + pull-request state for a remote `cmux ssh-tmux` mirror pane,
/// published by the remote agent hook into the `@cmux_git` tmux user option and
/// carried to cmux over the live control stream — the same zero-socket channel as
/// ``RemoteTmuxAgentStatus`` (Option C, `docs/investigations/remote-agent-status-sidebar.md`).
///
/// The remote repo lives on the SSH host, so cmux's local git/PR pollers can't see
/// it (they bail on `isRemoteWorkspace`). The hook already runs in the agent's cwd
/// inside that repo, so it runs `git`/`gh` there and publishes the result here;
/// the mirror maps it onto the workspace's per-panel `gitBranch` / `pullRequest`
/// sidebar models — the same rows a local workspace shows.
///
/// Pure parser; the option subscription lives in ``RemoteTmuxControlConnection``
/// and the sidebar write in ``RemoteTmuxSessionMirror``.
struct RemoteTmuxGitStatus: Equatable, Sendable {
    /// Lifecycle status of the PR, matching `SidebarPullRequestStatus` raw values.
    enum PullRequestStatus: String, Sendable {
        case open, merged, closed

        /// Maps `gh pr view` `.state` (OPEN/MERGED/CLOSED, any case) to a status.
        init?(ghState raw: String) {
            switch raw.trimmingCharacters(in: .whitespaces).lowercased() {
            case "open": self = .open
            case "merged": self = .merged
            case "closed": self = .closed
            default: return nil
            }
        }
    }

    struct PullRequest: Equatable, Sendable {
        let number: Int
        let url: URL
        let status: PullRequestStatus
        /// `owner/repo` label, when derivable from the PR url.
        let label: String
    }

    /// Current branch (non-empty), or `nil` when not in a git repo / detached.
    let branch: String?
    let isDirty: Bool
    /// The PR for the current branch, when `gh` found one.
    let pullRequest: PullRequest?

    /// Parses the `@cmux_git` option value: a JSON object
    /// `{branch?, dirty?, pr?: {number, url, state}}`. Returns `nil` for an empty
    /// value (the hook clears the option to drop the rows) or one carrying no
    /// usable branch/PR.
    static func parse(_ raw: String) -> RemoteTmuxGitStatus? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let data = trimmed.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        let branch = (obj["branch"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedBranch = (branch?.isEmpty == false) ? branch : nil
        // dirty accepts bool or the "0"/"1" string the shell hook emits.
        let isDirty: Bool
        switch obj["dirty"] {
        case let b as Bool: isDirty = b
        case let s as String: isDirty = (s.trimmingCharacters(in: .whitespaces) == "1")
        case let n as NSNumber: isDirty = n.intValue != 0
        default: isDirty = false
        }

        let pr = (obj["pr"] as? [String: Any]).flatMap(parsePullRequest)

        // Nothing useful → no rows.
        guard normalizedBranch != nil || pr != nil else { return nil }
        return RemoteTmuxGitStatus(branch: normalizedBranch, isDirty: isDirty, pullRequest: pr)
    }

    private static func parsePullRequest(_ obj: [String: Any]) -> PullRequest? {
        // number may be Int or numeric string ("#123" tolerated).
        let number: Int?
        switch obj["number"] {
        case let n as NSNumber: number = n.intValue
        case let s as String:
            let t = s.trimmingCharacters(in: .whitespaces)
            number = Int(t.hasPrefix("#") ? String(t.dropFirst()) : t)
        default: number = nil
        }
        guard let number, number > 0 else { return nil }

        guard let urlString = (obj["url"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              let url = URL(string: urlString),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https"
        else { return nil }

        let status = (obj["state"] as? String).flatMap(PullRequestStatus.init(ghState:)) ?? .open
        return PullRequest(number: number, url: url, status: status, label: repoLabel(from: url) ?? "PR")
    }

    /// Derives an `owner/repo` label from a GitHub PR URL
    /// (`https://github.com/owner/repo/pull/N` → `owner/repo`). `nil` when the
    /// path doesn't look like a PR url.
    static func repoLabel(from url: URL) -> String? {
        let parts = url.path.split(separator: "/").map(String.init)
        // /owner/repo/pull/N
        guard parts.count >= 4, parts[2] == "pull" else { return nil }
        return "\(parts[0])/\(parts[1])"
    }
}
