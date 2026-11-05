import Foundation

/// The acpmux MCP server's `wrap_up` tool (`acpmux_mcp_wrap_up.rs`): the agent's own end-of-turn
/// box. The agent calls it as the last step of a turn with `{recap, ask?, actions?}`; it arrives in
/// the transcript as an ordinary tool call, and this reads it back out so the turn draws it as the
/// next-step card under its answer and drops the call's own row. A port of the Mac's
/// `webviews/src/agent-session/acpmux/conversation/wrapUp.ts`. Leo, 2026-11-05: "I don't see the
/// box in iOS, in the app."
extension NextStepAsk {
    /// The tool's name on acpmux's own server; behind the folding `cmux` server it is
    /// `acpmux_wrap_up`, which a code-mode chat calls from a `cmux_exec` script.
    static let wrapUpTag = "wrap_up"
    private static let foldedWrapUp = "acpmux_wrap_up"
    /// The most answers a card draws; the tool asks for one or two.
    private static let maxWrapUpActions = 4
    /// A script's response larger than this is not read for its call log.
    private static let maxAnswerChars = 1_000_000

    nonisolated(unsafe) private static let claudeName = try? NSRegularExpression(pattern: #"^mcp__(.+?)__(.+)$"#)
    nonisolated(unsafe) private static let bareWrapUp = try? NSRegularExpression(
        pattern: #"^(?:(?:acpmux\.)?wrap_up|(?:cmux\.)?acpmux_wrap_up)$"#)
    nonisolated(unsafe) private static let cmuxServer = try? NSRegularExpression(
        pattern: #"^cmux(?:[-_](?:next|app|dev))?$"#, options: [.caseInsensitive])

    /// The MCP server and tool a call ran: Claude Code names it `mcp__<server>__<tool>` with the
    /// arguments as its input; Codex nests them under `{server, tool, arguments}`.
    private static func mcpCall(_ call: ACPToolCall) -> (server: String, tool: String, args: JSONValue?)? {
        let title = call.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if let claudeName, let match = claudeName.firstMatch(in: title, range: NSRange(title.startIndex..., in: title)),
           let server = Range(match.range(at: 1), in: title), let tool = Range(match.range(at: 2), in: title) {
            return (String(title[server]), String(title[tool]), call.rawInput)
        }
        if call.command == nil, let input = call.rawInput, let server = input["server"]?.stringValue,
           let tool = input["tool"]?.stringValue, let args = input["arguments"] {
            return (server, tool, args)
        }
        return nil
    }

    /// Whether a tool call is the wrap-up call, under any of the names a harness gives it. A
    /// `cmux_exec` script that called it is not: it may have done other work (`execWrapUp`).
    static func isWrapUp(_ call: ACPToolCall) -> Bool {
        guard call.command == nil else { return false }
        if let mcp = mcpCall(call) {
            return (mcp.server == "acpmux" && mcp.tool == wrapUpTag) || (mcp.server == "cmux" && mcp.tool == foldedWrapUp)
        }
        let title = call.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let bareWrapUp else { return false }
        return bareWrapUp.firstMatch(in: title, range: NSRange(title.startIndex..., in: title)) != nil
    }

    /// A finished `cmux_exec` script that called the wrap-up: what its last such call showed, and
    /// whether that call was all the script did, so its row can go.
    static func execWrapUp(_ call: ACPToolCall) -> (shown: [String: JSONValue], only: Bool)? {
        guard call.command == nil, let mcp = mcpCall(call), mcp.tool == "cmux_exec", let cmuxServer,
              cmuxServer.firstMatch(in: mcp.server, range: NSRange(mcp.server.startIndex..., in: mcp.server)) != nil,
              mentions(call.rawInput, foldedWrapUp) else { return nil }
        let text = call.outputText
        let answer = (text.isEmpty ? nil : findAnswer(.string(text), depth: 0)) ?? call.rawOutput.flatMap { findAnswer($0, depth: 0) }
        guard let log = answer?["call_log"]?.arrayValue else { return nil }
        let entries = log.compactMap { entry -> (name: String, ok: Bool, shown: [String: JSONValue]?)? in
            guard let name = entry["name"]?.stringValue else { return nil }
            var shown: [String: JSONValue]?
            if case .object(let object)? = entry["shown"] { shown = object }
            return (name, entry["ok"] == .bool(true), shown)
        }
        guard let last = entries.last(where: { $0.name == foldedWrapUp && $0.ok && $0.shown != nil }), let shown = last.shown else { return nil }
        return (shown, entries.allSatisfy { $0.name == foldedWrapUp })
    }

    /// The call's card: its recap, and its question with one to four answers. A question without
    /// answers gets Yes and Not now. Nil when the call carries no recap and no question, or failed.
    static func wrapUp(_ call: ACPToolCall) -> NextStepAsk? {
        guard call.status != .failed else { return nil }
        if let exec = execWrapUp(call) { return wrapUp(arguments: exec.shown) }
        var args = mcpCall(call)?.args ?? call.rawInput
        if case .string(let text)? = args { args = decode(text) }
        guard case .object(let object)? = args else { return nil }
        return wrapUp(arguments: object)
    }

    static func wrapUp(arguments args: [String: JSONValue]) -> NextStepAsk? {
        let recap = words(args["recap"])
        let question = words(args["ask"])
        guard recap != nil || question != nil else { return nil }
        var options: [Option] = []
        if question != nil {
            var labels: [String] = []
            for action in args["actions"]?.arrayValue ?? [] {
                guard let label = words(action) ?? words(action["label"]), label.count <= maxLabel, !labels.contains(label) else { continue }
                labels.append(label)
            }
            options = labels.isEmpty
                ? [Option(label: "Yes", kind: .yes), Option(label: "Not now", kind: .notNow)]
                : labels.prefix(maxWrapUpActions).map { Option(label: $0, kind: .listed) }
        }
        return NextStepAsk(tag: wrapUpTag, recap: recap, question: question ?? "", detail: nil, options: options, rest: "")
    }

    /// Whether a call is one the card stands in for, so its row goes: a finished wrap-up call that
    /// reads as a card, or a finished script whose only calls were the wrap-up.
    static func drawsWrapUp(_ call: ACPToolCall) -> Bool {
        guard call.status == .completed else { return false }
        if isWrapUp(call) { return wrapUp(call) != nil }
        return execWrapUp(call)?.only == true
    }

    /// The last wrap-up call among a turn's rows, read as its card.
    static func lastWrapUp(_ rows: [TurnRow]) -> NextStepAsk? {
        for row in rows.reversed() {
            let calls: [ACPToolCall]
            switch row {
            case .tool(let call): calls = [call]
            case .toolGroup(_, let group): calls = group
            default: continue
            }
            for call in calls.reversed() where isWrapUp(call) || execWrapUp(call) != nil {
                if let ask = wrapUp(call) { return ask }
            }
        }
        return nil
    }

    private static func words(_ value: JSONValue?) -> String? {
        guard let text = value?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text
    }

    private static func decode(_ text: String) -> JSONValue? {
        guard text.count <= maxAnswerChars, text.drop(while: \.isWhitespace).first == "{" else { return nil }
        return try? JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
    }

    /// Whether the call's input names `word` anywhere (a script's source holds the call).
    private static func mentions(_ value: JSONValue?, _ word: String) -> Bool {
        switch value {
        case .string(let text)?: text.contains(word)
        case .array(let items)?: items.contains { mentions($0, word) }
        case .object(let object)?: object.values.contains { mentions($0, word) }
        default: false
        }
    }

    /// The script's answer in its response: the object with its `call_log`, wherever the harness put
    /// it (the MCP result's structured content, its text block, or the text itself).
    private static func findAnswer(_ value: JSONValue, depth: Int) -> JSONValue? {
        guard depth <= 5 else { return nil }
        switch value {
        case .string(let text):
            return decode(text).flatMap { findAnswer($0, depth: depth + 1) }
        case .array(let items):
            return items.prefix(8).lazy.compactMap { findAnswer($0, depth: depth + 1) }.first
        case .object(let object):
            if object["call_log"]?.arrayValue != nil { return value }
            for key in ["structuredContent", "content", "text", "output", "result"] {
                if let inner = object[key], let found = findAnswer(inner, depth: depth + 1) { return found }
            }
            return nil
        default:
            return nil
        }
    }
}
