public import Foundation

/// The feed `feed.post` op for one pending acpmux prompt (the app's feed bridge posts it): what
/// the person must see to decide, named for the agent that asks.
///
/// - A tool permission posts as an `approve` request: tool, the exact command, a short input
///   summary; secret shapes scrubbed, env never sent. Anything cut or redacted is marked
///   `truncated` (cx-aocz): the phone shows it shortened and never allows it.
/// - A question (`acpmuxIsQuestion`) is never a permission (Leo 2026-10-21): no Allow or Deny.
///   With a `choice` (the question as a feed choice, every question and option whole) it posts as
///   a `choice` request the person answers inline; without one it posts as a notice naming the
///   agent and its question, answered in the chat.
public nonisolated struct AcpmuxFeedPost {
    /// A question as a feed choice (CmuxNextAgentQuestion `AgentQuestionFeedChoice`).
    public nonisolated struct Choice {
        public var title: String
        public var body: String
        public var prompt: [String: Any]

        public init(title: String, body: String, prompt: [String: Any]) {
            self.title = title
            self.body = body
            self.prompt = prompt
        }
    }

    public var session: String
    public var permission: String
    public var request: [String: Any]
    /// This Mac's install id (`context.host`), the install the phone's proof names.
    public var host: String
    /// The session's name ("claude", "Fix login"), shown as who posted it.
    public var agent: String?
    public var choice: Choice?

    public init(session: String, permission: String, request: [String: Any], host: String, agent: String? = nil, choice: Choice? = nil) {
        self.session = session
        self.permission = permission
        self.request = request
        self.host = host
        self.agent = agent
        self.choice = choice
    }

    /// Agent text as the feed may show it: secret shapes scrubbed, invisible characters dropped.
    public static func shown(_ text: String) -> String { text.secretsScrubbed.acpmuxVisible }

    /// The op: `{op: feed.post, params, idempotency_key, origin}`.
    public var body: [String: Any] {
        var params = request.acpmuxIsQuestion ? questionParams : approveParams
        params["context"] = ["host": String(host.prefix(128)), "acp_session": String(session.prefix(128))]
        params["dedupe_key"] = String(key.prefix(200))
        params["thread"] = String("acpmux:\(session)".prefix(200))
        return ["op": "feed.post", "params": params, "idempotency_key": String(key.prefix(200)), "origin": "script"]
    }

    private var key: String { "acpmux:\(permission)" }

    /// Who posted: the agent's own name, else "Agent".
    private func poster(_ name: String?) -> [String: Any] {
        let name = name.map { $0.acpmuxVisible.acpmuxCut(80) }.flatMap { $0.isEmpty ? nil : $0 }
        return ["label": name ?? String(localized: "feed.bridge.poster", defaultValue: "Agent", bundle: .module)]
    }

    private var approveParams: [String: Any] {
        let call = request["toolCall"] as? [String: Any] ?? [:]
        let rawTitle = call["title"] as? String ?? ""
        let title = rawTitle.secretsScrubbed.acpmuxVisible
        let kind = (call["kind"] as? String ?? "").acpmuxVisible
        let input = call["rawInput"] as? [String: Any] ?? [:]
        let rawCommand = input.acpmuxShownCommand
        let command = rawCommand.map { $0.secretsScrubbed.acpmuxVisible }
        let summary = input.acpmuxInputSummary
        // Anything cut, dropped or redacted: the phone shows it shortened and never allows it
        // (cx-aocz): a redaction must never hide what the person signs.
        let redacted = (rawCommand.map { $0.secretsScrubbed != $0 } ?? false)
            || rawTitle.secretsScrubbed != rawTitle
        let truncated = (command?.count ?? 0) > 8000 || title.count > 500 || kind.count > 200
            || redacted || (summary?.truncated ?? false)
        var action: [String: Any] = [
            "type": kind == "execute" ? "command" : kind == "edit" || kind == "delete" || kind == "move" ? "edit" : "tool",
            "summary": (title.isEmpty ? String(localized: "feed.bridge.summary", defaultValue: "An agent asks to run a tool", bundle: .module) : title).acpmuxCut(500),
        ]
        if !kind.isEmpty { action["tool"] = kind.acpmuxCut(200) }
        if let command, !command.isEmpty { action["command"] = command.acpmuxCut(8000) }
        if let summary { action["input"] = summary.fields }
        if truncated { action["truncated"] = true }
        let heading = String(localized: "feed.bridge.title", defaultValue: "Allow \((title.isEmpty ? kind : title).acpmuxCut(120))?", bundle: .module)
        var params: [String: Any] = [
            "type": "request",
            "kind": "approve",
            "title": heading.acpmuxCut(200),
            // The phone reads the Mac it answers from `context` (FeedApproveRequest).
            "prompt": ["action": action, "scopes": ["once"]],
            "poster": poster(agent),
        ]
        if let command, !command.isEmpty { params["body"] = command.acpmuxCut(4096) }
        return params
    }

    private var questionParams: [String: Any] {
        // The agent waits on the answer: push it as soon as a permission request, and let it
        // lapse with the request's 24 hours rather than a notice's week.
        var params: [String: Any] = ["priority": "high", "expires_in_ms": 86_400_000]
        if let choice {
            params.merge(["type": "request", "kind": "choice", "title": choice.title, "body": choice.body,
                          "prompt": choice.prompt, "poster": poster(agent)]) { _, new in new }
            return params
        }
        let call = request["toolCall"] as? [String: Any] ?? [:]
        let normalized = request.acpmuxQuestion
        let firstItem = (normalized?["items"] as? [[String: Any]])?.first
        let asked = ((call["rawInput"] as? [String: Any])?["questions"] as? [[String: Any]])?.first
        let text = (firstItem?["prompt"] as? String ?? asked?["question"] as? String ?? call["title"] as? String ?? "")
            .secretsScrubbed.acpmuxVisible.acpmuxCut(160)
        let named = agent ?? (normalized?["agent"] as? String)
        let name = named.map { $0.acpmuxVisible.acpmuxCut(60) }.flatMap { $0.isEmpty ? nil : $0 }
            ?? String(localized: "feed.bridge.question.agent", defaultValue: "An agent", bundle: .module)
        let heading = text.isEmpty
            ? String(localized: "feed.bridge.question.untitled", defaultValue: "\(name) asks a question", bundle: .module)
            : String(localized: "feed.bridge.question.title", defaultValue: "\(name) asks: \(text)", bundle: .module)
        params.merge(["type": "notice", "kind": "notice", "title": heading.acpmuxCut(200), "poster": poster(named)]) { _, new in new }
        return params
    }
}
