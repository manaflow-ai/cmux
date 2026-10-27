import CmuxNextCompat
import Foundation

/// One review thread of the branch's pull request (cx-ncc.77.2, Codex desktop's inline PR
/// comments): where it sits in the diff and what reviewers said. `git.pullRequest` with
/// `{action: "threads"}` answers `{url, number, threads}` (no pull request: no url and none).
public nonisolated struct AgentPaneGitReviewThread: Equatable, Sendable {
    public struct Comment: Equatable, Sendable {
        /// The author's login; empty for a deleted account.
        public var author: String
        public var body: String
        /// An https link to the comment on GitHub, the only kind the page links.
        public var url: String?
    }

    public var path: String
    /// The line on the head (nil: outdated, the line is gone).
    public var line: Int?
    /// "additions" for a thread on the new side, "deletions" for one on a removed line.
    public var side: String
    public var resolved: Bool
    public var outdated: Bool
    /// The file differs here from the pull request's head (an edit, a commit not pushed, one not
    /// pulled), so `line` may name another line: the page lists it above the diff.
    public var moved = false
    public var comments: [Comment]

    static let maximumThreads = 100
    static let maximumComments = 50
    static let maximumBody = 20_000

    /// GraphQL's non-null mark, spelled apart so the crash ratchet does not read it as an unwrap.
    private static let required = "!"
    /// The read, with the pull request's owner, name and number as variables.
    static let query = """
        query($owner: String\(required), $name: String\(required), $number: Int\(required)) { repository(owner: $owner, name: $name) {
          pullRequest(number: $number) { reviewThreads(last: \(maximumThreads)) { nodes {
            isResolved isOutdated path line diffSide
            comments(first: \(maximumComments)) { nodes { author { login } body url } } } } } } }
        """

    var json: [String: Any] {
        [
            "path": path, "line": line.map { $0 as Any } ?? NSNull(), "side": side, "resolved": resolved, "outdated": outdated,
            "moved": moved,
            "comments": comments.map { ["author": $0.author, "body": $0.body, "url": $0.url.map { $0 as Any } ?? NSNull()] },
        ]
    }

    /// The JSON object in gh's output, which may have warnings around it.
    static func object(in text: String) -> [String: Any]? {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}") else { return nil }
        return try? JSONSerialization.blockingJSONObject(with: Data(text[start...end].utf8)) as? [String: Any]
    }

    /// The threads in `gh api graphql`'s answer, nil when it is not one.
    static func list(fromGraphQL text: String) -> [AgentPaneGitReviewThread]? {
        guard let object = object(in: text),
              let repository = (object["data"] as? [String: Any])?["repository"] as? [String: Any],
              let pullRequest = repository["pullRequest"] as? [String: Any],
              let nodes = (pullRequest["reviewThreads"] as? [String: Any])?["nodes"] as? [[String: Any]] else { return nil }
        return nodes.prefix(maximumThreads).compactMap { node in
            guard let path = node["path"] as? String, !path.isEmpty else { return nil }
            let comments = ((node["comments"] as? [String: Any])?["nodes"] as? [[String: Any]] ?? []).prefix(maximumComments)
            return AgentPaneGitReviewThread(
                path: path, line: node["line"] as? Int,
                side: (node["diffSide"] as? String)?.uppercased() == "LEFT" ? "deletions" : "additions",
                resolved: node["isResolved"] as? Bool ?? false, outdated: node["isOutdated"] as? Bool ?? false,
                comments: comments.map { comment in
                    let url = comment["url"] as? String
                    return Comment(author: (comment["author"] as? [String: Any])?["login"] as? String ?? "",
                                   body: String((comment["body"] as? String ?? "").prefix(maximumBody)),
                                   url: url.flatMap { AgentPaneGitPullRequest.isPullRequestURL($0) ? $0 : nil })
                })
        }
    }

    /// The `gh api graphql` arguments for the pull request at `url` (https://host/owner/name/pull/N),
    /// nil for any other address. Owner and name go as raw strings (`-f`), so neither is read as a file.
    static func arguments(for url: String) -> [String]? {
        guard let parsed = URL(string: url), parsed.scheme == "https", let host = parsed.host?.lowercased() else { return nil }
        let parts = parsed.path.split(separator: "/").map(String.init)
        guard parts.count == 4, parts[2] == "pull", let number = Int(parts[3]), number > 0,
              [parts[0], parts[1]].allSatisfy(isName) else { return nil }
        return ["api", "graphql", "-f", "owner=\(parts[0])", "-f", "name=\(parts[1])", "-F", "number=\(number)",
                "-f", "query=\(query)"] + (host == "github.com" ? [] : ["--hostname", host])
    }

    private static func isName(_ text: String) -> Bool {
        !text.isEmpty && !text.hasPrefix("-") && text.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "-._".contains($0)) }
    }
}

extension AgentPaneGitPullRequest {
    /// The review threads of `folder`'s branch's open pull request, read with `gh` there (a merged
    /// or closed one's are not this work's). A thread on a file that differs here from the pull
    /// request's head is marked moved; every one is when that head is not here to compare.
    @concurrent static func threads(in folder: String, gh: String) async -> Outcome {
        let cli = { (arguments: [String]) in
            await AgentPaneGitProcess.output(arguments, executable: gh, directory: folder, timeout: networkTimeout, network: true)
        }
        let view = await cli(["pr", "view", "--json", "url,number,state,headRefOid"])
        guard view.status == 0 else {
            return view.text.contains("no pull requests found") ? .threads(url: nil, number: nil, []) : .refused(message(view))
        }
        guard let object = AgentPaneGitReviewThread.object(in: view.text), let url = object["url"] as? String,
              let arguments = AgentPaneGitReviewThread.arguments(for: url) else {
            return .refused(message(view))
        }
        guard (object["state"] as? String)?.uppercased() == "OPEN" else { return .threads(url: nil, number: nil, []) }
        let read = await cli(arguments)
        guard read.status == 0, var threads = AgentPaneGitReviewThread.list(fromGraphQL: read.text) else { return .refused(message(read)) }
        let changed = await changedSince(object["headRefOid"] as? String, in: folder)
        for index in threads.indices where changed?.contains(threads[index].path) ?? true { threads[index].moved = true }
        return .threads(url: url, number: object["number"] as? Int, threads)
    }

    /// The files whose working copy differs from `commit` (repository-relative), nil when it can't tell.
    private static func changedSince(_ commit: String?, in folder: String) async -> Set<String>? {
        guard let commit, commit.count == 40 || commit.count == 64, commit.allSatisfy(\.isHexDigit) else { return nil }
        let diff = await AgentPaneGitProcess.output(["-C", folder, "diff", "--no-relative", "--name-only", "--no-renames", commit, "--"],
                                                    timeout: localTimeout)
        guard diff.status == 0 else { return nil }
        return Set(diff.text.split(separator: "\n").map(String.init))
    }
}
