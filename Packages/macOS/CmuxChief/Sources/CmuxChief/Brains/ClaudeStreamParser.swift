import Foundation

/// What one Claude Code stdout line asks of the driver.
enum ClaudeStreamOutput: Sendable, Equatable {
    /// A turn event for the owner.
    case event(ChiefTurnEvent)
    /// Claude Code asks whether a tool may run (`can_use_tool`); the driver
    /// must answer with ``ClaudeStreamParser/permissionResponse(requestID:allow:input:)``.
    case permission(requestID: String, tool: String, input: ChiefJSON)
    /// A `can_use_tool` request that arrived while no turn of this driver
    /// runs, or from a stopped turn before the next prompt's echo; the
    /// driver must deny it.
    case stalePermission(requestID: String, input: ChiefJSON)
    /// A control request the driver does not handle; it answers with an error.
    case unsupportedControl(requestID: String, subtype: String)
}

/// Turns Claude Code's `--output-format stream-json` lines into Chief turn
/// events. Pure state, no process, so recorded stdout can drive it in tests.
///
/// It mirrors acpmux's Claude adapter (`claude_stdio/inbound.rs`):
///
/// - `stream_event` `text_delta` is live text; the `content_block_stop` of a
///   text block ends the segment.
/// - A `tool_use` block of an `assistant` line starts a tool; the matching
///   `tool_result` of a `user` line finishes it.
/// - `result` ends the turn, except the empty result a resumed process
///   prints at startup, and the late result of a turn that was interrupted.
/// - Lines with a `parent_tool_use_id` belong to a subagent and are skipped.
///
/// A turn that was stopped (``abandonTurn()``) may still print output and a
/// `result` after the next prompt was written. Until Claude Code echoes the
/// next prompt (`--replay-user-messages`), that output is the old turn's and
/// is dropped.
struct ClaudeStreamParser: Sendable {
    /// The session id from the last `system/init`.
    private(set) var sessionID: String?
    /// Whether a turn is running.
    private(set) var turnActive = false
    private var turnOutput = false
    private var awaitingEcho: String?
    private var abandoned = 0
    private var blockKinds: [Int: String] = [:]
    private var startedTools: Set<String> = []
    private var openText = false
    /// Lifts `cmux-question` / `cmux-result` blocks out of the reply text.
    var blocks = ChiefStructuredBlocks()

    init(sessionID: String? = nil) {
        self.sessionID = sessionID
    }

    /// Starts a turn whose prompt line carries `uuid`.
    mutating func beginTurn(echo uuid: String) {
        turnActive = true
        turnOutput = false
        awaitingEcho = uuid
        openText = false
        startedTools = []
        blocks.reset()
    }

    /// Ends the running turn early (Stop). Its late output and `result` are dropped.
    mutating func abandonTurn() {
        guard turnActive else { return }
        turnActive = false
        abandoned += 1
        awaitingEcho = nil
        openText = false
        startedTools = []
        blocks.reset()
    }

    /// Forgets per-process state after the process exited.
    mutating func processExited() {
        turnActive = false
        abandoned = 0
        awaitingEcho = nil
        openText = false
        startedTools = []
        blockKinds = [:]
        blocks.reset()
    }

    /// Output from an interrupted turn that arrives before the next prompt's echo.
    private var stale: Bool { !turnActive || (abandoned > 0 && awaitingEcho != nil) }

    /// Reads one stdout line; a line that is not JSON yields nothing.
    mutating func consume(_ line: Data) -> [ClaudeStreamOutput] {
        guard let json = try? ChiefJSON(parsing: line) else { return [] }
        return consume(json)
    }

    /// Reads one parsed stdout line. Reply text passes through ``blocks``.
    mutating func consume(_ line: ChiefJSON) -> [ClaudeStreamOutput] {
        let raw = consumeLine(line)
        blocks.session = sessionID
        return raw.flatMap { output -> [ClaudeStreamOutput] in
            guard case .event(let event) = output else { return [output] }
            return blocks.filter(event).map(ClaudeStreamOutput.event)
        }
    }

    private mutating func consumeLine(_ line: ChiefJSON) -> [ClaudeStreamOutput] {
        let type = line["type"]?.string ?? ""
        if type == "control_request" { return controlRequest(line) }
        if line["parent_tool_use_id"]?.string != nil { return [] }
        switch type {
        case "system":
            guard line["subtype"]?.string == "init", let id = line["session_id"]?.string, id != sessionID else { return [] }
            sessionID = id
            return turnActive ? [.event(.session(id))] : []
        case "user":
            return user(line)
        case "stream_event":
            return streamEvent(line["event"] ?? .null)
        case "assistant":
            return assistant(line)
        case "result":
            return result(line)
        default:
            return []
        }
    }

    private mutating func controlRequest(_ line: ChiefJSON) -> [ClaudeStreamOutput] {
        guard let id = line["request_id"]?.string else { return [] }
        let request = line["request"] ?? .null
        let subtype = request["subtype"]?.string ?? ""
        guard subtype == "can_use_tool" else { return [.unsupportedControl(requestID: id, subtype: subtype)] }
        // An interrupted turn can still ask after the next prompt was written.
        if stale { return [.stalePermission(requestID: id, input: request["input"] ?? [:])] }
        return [.permission(requestID: id, tool: request["tool_name"]?.string ?? "tool", input: request["input"] ?? [:])]
    }

    private mutating func user(_ line: ChiefJSON) -> [ClaudeStreamOutput] {
        if line["isReplay"]?.bool == true, let uuid = line["uuid"]?.string, uuid == awaitingEcho {
            // The stopped turn's result may still follow, before this
            // turn's own output; `result` handles it.
            awaitingEcho = nil
            return []
        }
        guard !stale, let content = line["message"]?["content"]?.array else { return [] }
        var out: [ClaudeStreamOutput] = []
        for block in content where block["type"]?.string == "tool_result" {
            guard let id = block["tool_use_id"]?.string, startedTools.remove(id) != nil else { continue }
            let ok = block["is_error"]?.bool != true
            out.append(.event(.toolFinished(id: id, ok: ok, preview: ChiefToolPolicy.preview(Self.text(of: block["content"])))))
        }
        return out
    }

    private mutating func streamEvent(_ event: ChiefJSON) -> [ClaudeStreamOutput] {
        let index = Int(event["index"]?.number ?? -1)
        switch event["type"]?.string {
        case "message_start":
            blockKinds = [:]
        case "content_block_start":
            blockKinds[index] = event["content_block"]?["type"]?.string
        case "content_block_delta":
            guard !stale, event["delta"]?["type"]?.string == "text_delta",
                  let text = event["delta"]?["text"]?.string, !text.isEmpty else { return [] }
            turnOutput = true
            openText = true
            return [.event(.textDelta(text))]
        case "content_block_stop":
            guard !stale, blockKinds[index] == "text" else { return [] }
            return endSegment()
        default:
            break
        }
        return []
    }

    private mutating func assistant(_ line: ChiefJSON) -> [ClaudeStreamOutput] {
        guard !stale, let content = line["message"]?["content"]?.array else { return [] }
        var out: [ClaudeStreamOutput] = []
        for block in content where block["type"]?.string == "tool_use" {
            guard let id = block["id"]?.string, !startedTools.contains(id) else { continue }
            startedTools.insert(id)
            turnOutput = true
            out += endSegment()
            let tool = block["name"]?.string ?? "tool"
            let input = block["input"] ?? [:]
            out.append(.event(.toolStarted(id: id, title: ChiefToolPolicy.claudeTitle(tool, input: input),
                                           detail: ChiefToolPolicy.claudeDetail(tool, input: input))))
        }
        return out
    }

    private mutating func result(_ line: ChiefJSON) -> [ClaudeStreamOutput] {
        let subtype = line["subtype"]?.string ?? ""
        let isError = line["is_error"]?.bool ?? false
        if !turnActive {
            if abandoned > 0 { abandoned -= 1 }
            return []
        }
        // The result of the stopped turn, before the next prompt was read
        // or before it printed anything.
        if abandoned > 0, awaitingEcho != nil || !turnOutput {
            abandoned -= 1
            return []
        }
        let startupNoise = subtype == "success" && !isError && !turnOutput
            && line["num_turns"]?.number == 0 && line["duration_api_ms"]?.number == 0
        if startupNoise { return [] }
        var out = endSegment()
        turnActive = false
        abandoned = 0
        awaitingEcho = nil
        startedTools = []
        let resultText = line["result"]?.string
        let interrupted = subtype == "error_during_execution" && (line["result"]?.isNull ?? true) && !isError
        if (isError || subtype.hasPrefix("error")) && !interrupted {
            out.append(.event(.failed(Self.failureMessage(line, subtype: subtype, text: resultText))))
        } else {
            // Before `.finished` only: output ahead of a failure would stop ClaudeCodeBrain's fresh-session retry.
            if let usage = Self.usage(line["usage"]) { out.append(.event(.usage(usage))) }
            out.append(.event(.finished))
        }
        return out
    }

    /// The `result` line's `usage` (input, cache read, cache write tokens); nil without input counts.
    static func usage(_ usage: ChiefJSON?) -> ChiefTurnUsage? {
        guard let usage else { return nil }
        let input = usage["input_tokens"]?.number
        let read = usage["cache_read_input_tokens"]?.number
        let write = usage["cache_creation_input_tokens"]?.number
        guard input != nil || read != nil || write != nil else { return nil }
        return ChiefTurnUsage(inputTokens: Int(input ?? 0), cacheReadTokens: Int(read ?? 0), cacheWriteTokens: Int(write ?? 0))
    }

    private mutating func endSegment() -> [ClaudeStreamOutput] {
        guard openText else { return [] }
        openText = false
        return [.event(.textSegmentEnd)]
    }

    private static func failureMessage(_ line: ChiefJSON, subtype: String, text: String?) -> String {
        if let text, !text.isEmpty { return text }
        let errors = (line["errors"]?.array ?? []).compactMap { $0.string ?? $0["message"]?.string }
        if !errors.isEmpty { return errors.joined(separator: "\n") }
        switch subtype {
        case "error_max_turns": return "Claude Code stopped: too many turns."
        default: return "Claude Code failed (\(subtype.isEmpty ? "error" : subtype))."
        }
    }

    /// The text of a `tool_result` content: a string or text blocks.
    static func text(of content: ChiefJSON?) -> String {
        switch content {
        case .string(let text)?:
            return text
        case .array(let blocks)?:
            return blocks.compactMap { $0["text"]?.string }.joined(separator: "\n")
        default:
            return ""
        }
    }

    // MARK: Lines for Claude Code's stdin

    /// The `initialize` control request acpmux sends first.
    static func initializeRequest(id: String) -> ChiefJSON {
        ["type": "control_request", "request_id": .string(id),
         "request": ["subtype": "initialize", "hooks": [:],
                     "supportedDialogKinds": ["ask_user_question", "exit_plan_mode", "permission"]]]
    }

    /// A user prompt line; Claude Code echoes it with the same `uuid`.
    static func userMessage(uuid: String, content: [ChiefJSON]) -> ChiefJSON {
        ["type": "user", "uuid": .string(uuid), "message": ["role": "user", "content": .array(content)]]
    }

    /// The interrupt control request (Stop).
    static func interruptRequest(id: String) -> ChiefJSON {
        ["type": "control_request", "request_id": .string(id), "request": ["subtype": "interrupt"]]
    }

    /// The answer to a `can_use_tool` request.
    static func permissionResponse(requestID: String, allow: Bool, input: ChiefJSON) -> ChiefJSON {
        let response: ChiefJSON = allow
            ? ["behavior": "allow", "updatedInput": input]
            : ["behavior": "deny", "message": "The user rejected this action."]
        return ["type": "control_response",
                "response": ["subtype": "success", "request_id": .string(requestID), "response": response]]
    }

    /// The error answer to a control request the driver does not support.
    static func unsupportedResponse(requestID: String, subtype: String) -> ChiefJSON {
        ["type": "control_response",
         "response": ["subtype": "error", "request_id": .string(requestID),
                      "error": .string("cmux Chief does not support control request \(subtype)")]]
    }
}
