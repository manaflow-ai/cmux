public import CmuxNextAgentPane
public import CmuxNextDaemon
public import Foundation

/// A pull request's diff from commits already on this Mac, before GitHub's: the session host's
/// `git.diff` in the `commits` scope (head against its merge base with base, as GitHub's diff is)
/// in a chat folder that is a checkout of its repository (``AgentReplyPullRequests/folders(of:)``).
/// The chat that opened or worked on a pull request has its commits, so its diff opens in tens of
/// milliseconds instead of a `gh pr diff` round trip to GitHub. Nothing is fetched: a fetch costs
/// GitHub's ref advertisement alone, as long as the diff itself. A folder without both commits,
/// a closed or merged pull request (its head is in its base, so the merge base is the head), and
/// any reply that leaves a file or a patch out answer nil, and the caller reads GitHub's.
public struct GitHubLocalDiff: Sendable {
    /// The session host's `git.diff` with `params`: the App's local git link; nil when it refused
    /// or got no answer.
    public typealias Read = @MainActor (_ params: [String: CmuxNextDaemon.JSONValue]) async -> Data?

    /// What to read for one pull request: its commits, and the folders that may hold them.
    nonisolated struct Plan: Equatable, Sendable {
        let folders: [String]
        let base: String
        let head: String
    }

    private let cache: AgentReplyPullRequests
    private let read: Read

    public init(cache: AgentReplyPullRequests = .shared, read: @escaping Read) {
        self.cache = cache
        self.read = read
    }

    /// Nil unless the cache has `link` open with both commits and this Mac has a checkout of its
    /// repository.
    func plan(_ link: GitHubLink) -> Plan? {
        guard let pullRequest = cache.answer(link.url, read: false).pullRequest,
              pullRequest.state == "open" || pullRequest.state == "draft",
              !pullRequest.baseCommit.isEmpty, !pullRequest.headCommit.isEmpty else { return nil }
        let folders = cache.folders(of: link.repository)
        guard !folders.isEmpty else { return nil }
        return Plan(folders: folders, base: pullRequest.baseCommit, head: pullRequest.headCommit)
    }

    /// The first folder's whole diff for `plan`, as `gh pr diff` prints one; nil when none has it.
    func diff(_ plan: Plan) async -> String? {
        for folder in plan.folders {
            let params: [String: CmuxNextDaemon.JSONValue] = [
                "path": .string(folder), "scope": .string("commits"), "base": .string(plan.base), "head": .string(plan.head),
                "include_patch": .bool(true), "max_files": .number(5_000), "max_patch_bytes": .number(4_194_304),
            ]
            guard let data = await read(params) else { continue }
            if let text = await Self.unified(data) { return text }
        }
        return nil
    }

    /// A `git.diff` reply as one unified diff, each file's header rebuilt from its path and
    /// status (the reply's patches start at the first hunk); nil when the reply left a file or
    /// a patch out, so a partial diff never stands in for the whole one. Off the main thread: a
    /// reply can be megabytes.
    @concurrent nonisolated static func unified(_ data: Data) async -> String? {
        guard let reply = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (reply["files_omitted"] as? Int ?? 0) == 0, let files = reply["files"] as? [[String: Any]] else { return nil }
        var text = ""
        for file in files {
            guard let path = file["path"] as? String, file["patch_truncated"] as? Bool != true else { return nil }
            let status = file["status"] as? String ?? "modified"
            let old = status == "renamed" ? file["previous_path"] as? String ?? path : path
            text += "diff --git a/\(old) b/\(path)\n"
            switch status {
            case "added": text += "new file mode 100644\n"
            case "deleted": text += "deleted file mode 100644\n"
            case "renamed": text += "rename from \(old)\nrename to \(path)\n"
            default: break
            }
            if file["binary"] as? Bool == true {
                text += "Binary files \(status == "added" ? "/dev/null" : "a/\(old)") and \(status == "deleted" ? "/dev/null" : "b/\(path)") differ\n"
                continue
            }
            guard let patch = file["patch"] as? String, !patch.isEmpty else {
                // A file with changed lines and no patch was cut from the reply.
                if (file["additions"] as? Int ?? 0) + (file["deletions"] as? Int ?? 0) > 0 { return nil }
                continue
            }
            text += "--- \(status == "added" ? "/dev/null" : "a/\(old)")\n+++ \(status == "deleted" ? "/dev/null" : "b/\(path)")\n"
            text += patch.hasSuffix("\n") ? patch : patch + "\n"
        }
        return text.isEmpty ? nil : text
    }
}
