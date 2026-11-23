import Foundation

/// A pull request a chat opened, as far as its Mac knows it: the Feed card's and the workspace
/// row's "PR #123 · checks passing" (manaflow-ai/cmux#51332).
public struct PullRequestSummary: Hashable, Sendable, Codable {
    public enum State: String, Hashable, Sendable, Codable {
        case open, draft, merged, closed
    }

    /// The checks of its head, rolled up.
    public enum Checks: String, Hashable, Sendable, Codable {
        case passing, failing, pending
    }

    public var url: URL
    public var number: Int
    public var title: String?
    /// Nil: the Mac named the pull request but not its state (it reads as open).
    public var state: State?
    public var checks: Checks?
    /// GitHub says it merges cleanly; nil when unknown.
    public var mergeable: Bool?

    public init(url: URL, number: Int, title: String? = nil, state: State? = nil, checks: Checks? = nil, mergeable: Bool? = nil) {
        self.url = url
        self.number = number
        self.title = title
        self.state = state
        self.checks = checks
        self.mergeable = mergeable
    }

    /// `https://github.com/OWNER/REPO/pull/N` (a trailing path or query is dropped); nil for any other link.
    public init?(link: String) {
        guard let url = URL(string: link.trimmingCharacters(in: .whitespacesAndNewlines)), url.scheme == "https",
              url.host() == "github.com" else { return nil }
        let parts = url.path.split(separator: "/")
        guard parts.count >= 4, parts[2] == "pull", let number = Int(parts[3]), number > 0,
              let clean = URL(string: "https://github.com/\(parts[0])/\(parts[1])/pull/\(number)") else { return nil }
        self.init(url: clean, number: number)
    }

    /// The repository's name ("cmux"), from the link.
    public var repository: String { url.pathComponents.count > 2 ? url.pathComponents[2] : "" }

    public var isMerged: Bool { state == .merged }
    public var isClosed: Bool { state == .closed }
    public var isOpen: Bool { state == nil || state == .open || state == .draft }

    /// Ready for the person to merge: open, not a draft, no failing or pending check, and not known
    /// to conflict. Merge is offered only then.
    public var canMerge: Bool {
        (state == nil || state == .open) && checks != .failing && checks != .pending && mergeable != false
    }

    /// "Merged", "Closed", "Draft", "Checks failing", "Checks running", "Checks passing", "Conflicts", else "Open".
    public var stateText: String {
        switch state {
        case .merged: return "Merged"
        case .closed: return "Closed"
        case .draft: return "Draft"
        case .open, nil: break
        }
        switch checks {
        case .failing: return "Checks failing"
        case .pending: return "Checks running"
        case .passing: return mergeable == false ? "Conflicts" : (mergeable == true ? "Ready to merge" : "Checks passing")
        case nil: return mergeable == false ? "Conflicts" : "Open"
        }
    }

    /// The more one of two reads of the same pull request says (a list summary and a fuller read).
    public func merged(with other: PullRequestSummary) -> PullRequestSummary {
        var next = self
        next.title = other.title ?? title
        next.state = other.state ?? state
        next.checks = other.checks ?? checks
        next.mergeable = other.mergeable ?? mergeable
        return next
    }
}

/// What an agent chat did last, for the lines that summarize it (a workspace row's second line, a
/// Feed card's headline): its last reply's first line, whether its last turn failed, and the pull
/// request it opened. Built from the Mac's acpmux session summary (`AcpmuxSession`).
public struct ChatActivity: Hashable, Sendable, Codable {
    /// The first line of the agent's last reply, plain text, at most 140 characters.
    public var lastLine: String?
    public var failed: Bool
    /// The newest pull request the chat opened.
    public var pullRequest: PullRequestSummary?
    /// The cmux dev build the chat made or names (its tag), when it says.
    public var devBuild: String?

    public init(lastLine: String? = nil, failed: Bool = false, pullRequest: PullRequestSummary? = nil, devBuild: String? = nil) {
        self.lastLine = lastLine
        self.failed = failed
        self.pullRequest = pullRequest
        self.devBuild = devBuild
    }

    public var isEmpty: Bool { lastLine == nil && !failed && pullRequest == nil && devBuild == nil }

    /// `text`'s first line with words in it, markdown marks dropped, at most `limit` characters.
    public static func firstLine(_ text: String, limit: Int = 140) -> String? {
        for raw in text.split(whereSeparator: \.isNewline) {
            var line = raw.trimmingCharacters(in: .whitespaces)
            // Headings, list bullets, quotes and fences say nothing on their own.
            while let first = line.first, "#>-*`|".contains(first) { line = String(line.dropFirst()).trimmingCharacters(in: .whitespaces) }
            line = line.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "__", with: "")
                .replacingOccurrences(of: "`", with: "")
            // A markdown link reads as its text.
            line = line.replacingOccurrences(of: #"\[([^\]]+)\]\([^)]+\)"#, with: "$1", options: .regularExpression)
            line = line.trimmingCharacters(in: .whitespaces)
            guard line.count >= 2 else { continue }
            return line.count > limit ? String(line.prefix(limit - 1)).trimmingCharacters(in: .whitespaces) + "…" : line
        }
        return nil
    }

    /// A dev build tag a reply names: "tag `feed-threads`", "Tag Opener http://127.0.0.1:17320/<tag>",
    /// "dev build <tag>", "--tag <tag>".
    public static func devBuildTag(in text: String) -> String? {
        guard text.contains("17320") || text.range(of: "tag", options: .caseInsensitive) != nil
            || text.range(of: "dev build", options: .caseInsensitive) != nil else { return nil }
        for regex in devBuildPatterns {
            guard let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                  let range = Range(match.range(at: 1), in: text) else { continue }
            return String(text[range])
        }
        return nil
    }

    /// Compiled once: a summary is read again on every change the Mac reports.
    nonisolated(unsafe) private static let devBuildPatterns: [NSRegularExpression] = [
        #"127\.0\.0\.1:17320/([A-Za-z0-9][A-Za-z0-9._-]{1,60})"#,
        #"(?i)dev build[^\n`]{0,12}`([A-Za-z0-9][A-Za-z0-9._-]{1,60})`"#,
        #"(?i)\btag[: ]+`([A-Za-z0-9][A-Za-z0-9._-]{1,60})`"#,
        #"--tag[ =]([A-Za-z0-9][A-Za-z0-9._-]{1,60})"#,
    ].compactMap { try? NSRegularExpression(pattern: $0) }
    nonisolated(unsafe) private static let pullLink = try? NSRegularExpression(
        pattern: #"https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/pull/[0-9]+"#)

    /// The pull request links a reply names, in order, once each.
    public static func pullRequests(in text: String) -> [PullRequestSummary] {
        guard text.contains("/pull/"), let regex = pullLink else { return [] }
        var seen = Set<URL>()
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
            guard let range = Range(match.range, in: text), let pull = PullRequestSummary(link: String(text[range])),
                  seen.insert(pull.url).inserted else { return nil }
            return pull
        }
    }
}

/// The agent a harness profile runs, as a person names it: `claude-sr2`, `claude-cr` and `claude`
/// are all "Claude" (a profile id is how the Mac routes the agent, not who answered; #51332).
public enum HarnessName {
    /// `claude-sr2` → `claude`: the first word of the profile id, lowercased.
    public static func family(_ harness: String) -> String {
        harness.split(whereSeparator: { "-_/ ".contains($0) }).first.map { $0.lowercased() } ?? ""
    }

    /// "Claude", "Codex", "Gemini", "OpenCode", "Cursor", else the family capitalized, else "Agent".
    public static func display(_ harness: String?) -> String {
        let family = family(harness ?? "")
        switch family {
        case "": return "Agent"
        case "claude": return "Claude"
        case "codex": return "Codex"
        case "gemini": return "Gemini"
        case "opencode": return "OpenCode"
        case "cursor": return "Cursor"
        case "chief": return "Chief"
        default: return family.prefix(1).uppercased() + family.dropFirst()
        }
    }
}
