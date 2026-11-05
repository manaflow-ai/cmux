import Foundation

/// "Who else is working on these files": acpmux's answer (`_acpmux/who_else`, schema
/// `acpmux.who-else.v1`) as a tool call carries it, whichever way the agent asked. The acpmux MCP
/// `who_else` tool (Claude's `mcp__acpmux__who_else`, Codex's `{server, tool, arguments}`, or folded
/// into cmux_exec as `acpmux_who_else`) returns it as structured content; `acpmux --json who-else`
/// in a shell prints it. Either draws as one card (`WhoElseCard`), never raw JSON in the transcript.
/// A port of the Mac's `webviews/src/agent-session/acpmux/conversation/whoElseCalls.ts`.
public struct WhoElseCall: Hashable, Sendable {
    public struct File: Hashable, Sendable {
        public var path: String
        public var edited: Bool
        /// When the session last touched it (epoch ms), when acpmux says.
        public var at: Double?
    }

    public struct Session: Hashable, Sendable, Identifiable {
        public var sessionId: String
        public var name: String
        /// The name to open or message it by: `HOST/NAME` for a peer's session, else its name.
        public var ref: String
        public var title: String?
        public var harness: String
        /// The peer machine it runs on; nil for a session of this chat's own acpmux.
        public var host: String?
        public var status: String
        public var live: Bool
        public var branch: String?
        public var pullRequests: [String]
        public var agoMs: Double
        public var filesInCommon: Int
        public var editedInCommon: Int
        public var files: [File]
        public var sameWorktree: Bool
        public var sameBranch: Bool
        public var topicWords: [String]

        public var id: String { "\(host ?? "")/\(sessionId)" }
    }

    public struct Answer: Hashable, Sendable {
        public var sessions: [Session]
        /// Sessions acpmux matched but left out of `sessions`.
        public var more: Int
        /// Peers that did not answer in time.
        public var unreached: [String]
        /// The files the question named (up to 20) and how many in all.
        public var files: [String]
        public var fileCount: Int
        public var topic: String?
    }

    /// Still running: no answer yet.
    public var pending: Bool
    public var answer: Answer?

    public static let schema = "acpmux.who-else.v1"
    /// Rows the card shows before "N more" opens the rest.
    public static let rowsShown = 5
    /// Files listed per row; the count says the rest.
    static let filesShown = 3

    nonisolated(unsafe) private static let toolName = try? NSRegularExpression(
        pattern: #"^(?:acpmux[_.]|acpmux__)?who_?else$"#, options: [.caseInsensitive])
    nonisolated(unsafe) private static let cli = try? NSRegularExpression(
        pattern: #"(?:^|(?:&&|\|\||;)\s*)(?:\w+=\S+\s+)*(?:\S+/)?acpmux(?:-debug-cli)?\s+(?:--json\s+)?(?:who-?else|overlap)(?:\s|$)"#,
        options: [.caseInsensitive])
    nonisolated(unsafe) private static let jsonFlag = try? NSRegularExpression(pattern: #"--json\b"#)
    nonisolated(unsafe) private static let claudeName = try? NSRegularExpression(pattern: #"^mcp__(.+?)__(.+)$"#)
    nonisolated(unsafe) private static let pullNumber = try? NSRegularExpression(pattern: #"/pull/(\d+)"#)

    /// The who-else question `call` asks, with its answer once there, or nil for any other call. A
    /// shell call counts only when it asked for `--json` (a text answer stays shell output).
    public init?(_ call: ACPToolCall) {
        guard Self.asksWhoElse(call) else { return nil }
        let pending = call.isRunning
        let answer = Self.findAnswer(call.rawOutput, depth: 0) ?? Self.findAnswer(Self.json(call.outputText), depth: 0)
        if answer == nil, !pending { return nil }
        self.init(pending: pending && answer == nil, answer: answer)
    }

    init(pending: Bool, answer: Answer?) {
        self.pending = pending
        self.answer = answer
    }

    static func asksWhoElse(_ call: ACPToolCall) -> Bool {
        // Another server's tool of the same name is that server's: its output draws as itself.
        if let mcp = mcpCall(call) { return ["acpmux", "cmux"].contains(mcp.server.lowercased()) && matches(toolName, mcp.tool) }
        if matches(toolName, call.title.trimmingCharacters(in: .whitespacesAndNewlines)) { return true }
        guard let command = call.command else { return false }
        return matches(cli, command) && matches(jsonFlag, command)
    }

    /// The MCP server and tool a call ran: Claude Code names it `mcp__<server>__<tool>`; Codex nests
    /// them under `{server, tool, arguments}` (the Mac's `mcpCalls.ts`).
    static func mcpCall(_ call: ACPToolCall) -> (server: String, tool: String)? {
        let title = call.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if let claudeName, let match = claudeName.firstMatch(in: title, range: NSRange(title.startIndex..., in: title)),
           let server = Range(match.range(at: 1), in: title), let tool = Range(match.range(at: 2), in: title) {
            return (String(title[server]), String(title[tool]))
        }
        guard call.command == nil, case .object(let input)? = call.rawInput, input["arguments"] != nil,
              let server = input["server"]?.stringValue, let tool = input["tool"]?.stringValue else { return nil }
        return (server, tool)
    }

    /// The answer anywhere in `value`: the object itself, an MCP result's structured content or text
    /// block, or a cmux_exec envelope around one. At most a few levels down.
    static func findAnswer(_ value: JSONValue?, depth: Int) -> Answer? {
        guard depth <= 4, let value else { return nil }
        switch value {
        case .string(let text):
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix("{") || trimmed.hasPrefix("[") else { return nil }
            return findAnswer(json(trimmed), depth: depth + 1)
        case .array(let entries):
            for entry in entries {
                if let found = findAnswer(entry, depth: depth + 1) { return found }
            }
            return nil
        case .object(let object):
            if object["schema"]?.stringValue == schema, let sessions = object["sessions"]?.arrayValue {
                return parsedAnswer(object, sessions: sessions)
            }
            for key in ["structuredContent", "result", "value", "content", "text", "output"] {
                if let found = findAnswer(object[key], depth: depth + 1) { return found }
            }
            return nil
        default:
            return nil
        }
    }

    private static func parsedAnswer(_ raw: [String: JSONValue], sessions: [JSONValue]) -> Answer {
        let query = raw["query"]
        return Answer(
            sessions: sessions.compactMap { entry -> Session? in
                guard case .object(let session) = entry else { return nil }
                return Self.session(session)
            },
            more: int(raw["more"]),
            unreached: (raw["unreached"]?.arrayValue ?? []).compactMap { $0["host"]?.stringValue },
            files: strings(query?["files"]),
            fileCount: int(query?["fileCount"]),
            topic: text(query?["topic"]))
    }

    private static func session(_ raw: [String: JSONValue]) -> Session {
        let name = text(raw["name"]) ?? text(raw["sessionId"]) ?? ""
        let files: [File] = (raw["files"]?.arrayValue ?? []).compactMap { file in
            guard let path = text(file["path"]) else { return nil }
            return File(path: path, edited: file["edited"] == .bool(true), at: file["at"]?.numberValue)
        }
        return Session(
            sessionId: text(raw["sessionId"]) ?? "", name: name, ref: text(raw["ref"]) ?? name, title: text(raw["title"]),
            harness: text(raw["harness"]) ?? "", host: text(raw["host"]), status: text(raw["status"]) ?? "",
            live: raw["live"] == .bool(true), branch: text(raw["branch"]), pullRequests: strings(raw["pullRequests"]).filter(isPullLink),
            agoMs: raw["agoMs"]?.numberValue.flatMap { $0.isFinite ? $0 : nil } ?? 0,
            filesInCommon: int(raw["filesInCommon"]), editedInCommon: int(raw["editedInCommon"]), files: files,
            sameWorktree: raw["sameWorktree"] == .bool(true), sameBranch: raw["sameBranch"] == .bool(true),
            topicWords: strings(raw["topicWords"]))
    }

    /// `#123` for a pull request URL, else the URL's last part.
    public static func pullLabel(_ url: String) -> String {
        if let pullNumber, let match = pullNumber.firstMatch(in: url, range: NSRange(url.startIndex..., in: url)),
           let number = Range(match.range(at: 1), in: url) {
            return "#\(url[number])"
        }
        return url.split(separator: "/").last.map(String.init) ?? url
    }

    private static func matches(_ regex: NSRegularExpression?, _ text: String) -> Bool {
        regex?.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    private static func text(_ value: JSONValue?) -> String? {
        guard let string = value?.stringValue, !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return string
    }

    private static func int(_ value: JSONValue?) -> Int {
        guard let number = value?.numberValue, number.isFinite, abs(number) < Double(Int.max) else { return 0 }
        return Int(number)
    }

    /// Tool output is untrusted: a link is drawn only to an https URL with a host and no
    /// credentials (the Mac's `safeHref`), never `javascript:` or `data:`.
    static func isPullLink(_ text: String) -> Bool {
        guard let url = URL(string: text), url.scheme?.lowercased() == "https" else { return false }
        return url.host?.isEmpty == false && url.user == nil && url.password == nil
    }

    private static func strings(_ value: JSONValue?) -> [String] {
        (value?.arrayValue ?? []).compactMap(\.stringValue)
    }

    private static func json(_ text: String) -> JSONValue? {
        guard !text.isEmpty else { return nil }
        guard let value = try? JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)) else { return .string(text) }
        return value
    }
}

// MARK: Wording (the Mac's `whoElse.*` strings)

extension WhoElseCall {
    /// The card's line: still looking, nobody else, or how many other sessions.
    public var line: String {
        if pending {
            return String(localized: "mobile.agentChat.whoElse.looking", defaultValue: "Looking for who else works on these files…", bundle: .module)
        }
        let count = answer?.sessions.count ?? 0
        switch count {
        case 0: return String(localized: "mobile.agentChat.whoElse.none", defaultValue: "No other session works on these files", bundle: .module)
        case 1: return String(localized: "mobile.agentChat.whoElse.one", defaultValue: "1 other session works on these files", bundle: .module)
        default:
            return String(localized: "mobile.agentChat.whoElse.many", defaultValue: "\(count) other sessions work on these files", bundle: .module)
        }
    }

    /// The rows past the first `shown` plus those acpmux left out (the "N more" button's count).
    public func hiddenCount(shown: Int) -> Int {
        max(0, (answer?.sessions.count ?? 0) - shown + (answer?.more ?? 0))
    }

    /// "+N more".
    static func more(_ count: Int) -> String {
        String(localized: "mobile.agentChat.whoElse.more", defaultValue: "+\(count) more", bundle: .module)
    }

    /// "Not asked: hosts" for peers that did not answer; nil when every one did.
    public var unreachedNote: String? {
        guard let hosts = answer?.unreached, !hosts.isEmpty else { return nil }
        let list = hosts.joined(separator: ", ")
        return String(localized: "mobile.agentChat.whoElse.unreached", defaultValue: "Not asked: \(list)", bundle: .module)
    }
}

extension WhoElseCall.Session {
    /// The chip's name: `HOST/NAME` for a peer's session.
    public var displayName: String { host.map { "\($0)/\(name)" } ?? name }

    /// "harness · branch".
    public var whereText: String {
        [harness, branch ?? ""].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// What it has in common: `edited a.rs, b.rs · read c.rs · +2 more · in this worktree`, or why it matched.
    public var whatText: String {
        let base = { (path: String) in (path as NSString).lastPathComponent }
        let edited = files.filter(\.edited).prefix(WhoElseCall.filesShown)
        let read = files.filter { !$0.edited }.prefix(max(0, WhoElseCall.filesShown - edited.count))
        var parts: [String] = []
        if !edited.isEmpty {
            let list = edited.map { base($0.path) }.joined(separator: ", ")
            parts.append(String(localized: "mobile.agentChat.whoElse.edited", defaultValue: "edited \(list)", bundle: .module))
        }
        if !read.isEmpty {
            let list = read.map { base($0.path) }.joined(separator: ", ")
            parts.append(String(localized: "mobile.agentChat.whoElse.read", defaultValue: "read \(list)", bundle: .module))
        }
        let rest = filesInCommon - edited.count - read.count
        if rest > 0 { parts.append(WhoElseCall.more(rest)) }
        if sameWorktree { parts.append(String(localized: "mobile.agentChat.whoElse.sameWorktree", defaultValue: "in this worktree", bundle: .module)) }
        if sameBranch { parts.append(String(localized: "mobile.agentChat.whoElse.sameBranch", defaultValue: "on this branch", bundle: .module)) }
        if !topicWords.isEmpty {
            let words = topicWords.joined(separator: ", ")
            parts.append(String(localized: "mobile.agentChat.whoElse.topic", defaultValue: "topic: \(words)", bundle: .module))
        }
        return parts.joined(separator: " · ")
    }

    /// "now", "4m ago", "3h ago" (under two days), else "2d ago".
    public var agoText: String {
        let minutes = Int((agoMs / 60_000).rounded(.down))
        if minutes < 1 { return String(localized: "mobile.agentChat.whoElse.now", defaultValue: "now", bundle: .module) }
        if minutes < 60 { return String(localized: "mobile.agentChat.whoElse.minutes", defaultValue: "\(minutes)m ago", bundle: .module) }
        if minutes < 48 * 60 {
            let hours = minutes / 60
            return String(localized: "mobile.agentChat.whoElse.hours", defaultValue: "\(hours)h ago", bundle: .module)
        }
        let days = minutes / 1440
        return String(localized: "mobile.agentChat.whoElse.days", defaultValue: "\(days)d ago", bundle: .module)
    }
}
