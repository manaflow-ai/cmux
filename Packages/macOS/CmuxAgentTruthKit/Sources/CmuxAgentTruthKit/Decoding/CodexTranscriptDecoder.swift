public import CmuxAgentReplica
import Foundation

/// Decodes Codex rollout JSONL transcripts into fail-open entries.
public struct CodexTranscriptDecoder: TranscriptDecoder, Sendable {
    private let lineDecoder: JSONLineDecoder
    private var pendingCalls: [String: PendingToolUse]
    private var sawCompactedRecord: Bool

    /// Creates a Codex transcript decoder.
    public init() {
        self.lineDecoder = JSONLineDecoder()
        self.pendingCalls = [:]
        self.sawCompactedRecord = false
    }

    /// Feeds Codex rollout lines at their absolute line index.
    /// - Parameters:
    ///   - lines: The raw JSONL lines.
    ///   - startingAt: The absolute line index for the first line.
    ///   - journalID: The journal id that owns emitted entries.
    /// - Returns: The decoded entries and diagnostics emitted by this feed.
    public mutating func feed(_ lines: [String], startingAt: Int, journalID: JournalID) -> TranscriptDecodeBatch {
        var accumulator = TranscriptDecodeAccumulator()
        for (offset, line) in lines.enumerated() {
            decodeLine(line, lineIndex: startingAt + offset, journalID: journalID, accumulator: &accumulator)
        }
        return accumulator.batch()
    }

    private mutating func decodeLine(
        _ line: String,
        lineIndex: Int,
        journalID: JournalID,
        accumulator: inout TranscriptDecodeAccumulator
    ) {
        guard let root = lineDecoder.decode(line)?.object else {
            accumulator.countUnknown("malformed")
            accumulator.emit(payload: unknownPayload(rawKind: "malformed", summary: "Malformed transcript line", raw: line), journalID: journalID, lineIndex: lineIndex)
            return
        }
        guard let type = root["type"]?.string else {
            accumulator.countUnknown("missing_type")
            accumulator.emit(payload: unknownPayload(rawKind: "missing_type", summary: "Missing Codex record type", raw: line), journalID: journalID, lineIndex: lineIndex)
            return
        }
        switch type {
        case "session_meta":
            decodeSessionMeta(root, raw: line, lineIndex: lineIndex, journalID: journalID, accumulator: &accumulator)
        case "response_item":
            decodeResponseItem(root["payload"]?.object ?? root, raw: line, lineIndex: lineIndex, journalID: journalID, accumulator: &accumulator)
        case "event_msg":
            decodeEventMessage(root["payload"]?.object ?? root, raw: line, lineIndex: lineIndex, journalID: journalID, accumulator: &accumulator)
        case "compacted":
            sawCompactedRecord = true
            accumulator.emit(payload: .status(StatusPayload(code: .compacted, detail: "Context compacted")), journalID: journalID, lineIndex: lineIndex)
        case "turn_context":
            decodeTurnContext(root["payload"]?.object ?? root, lineIndex: lineIndex, accumulator: &accumulator)
        default:
            accumulator.countUnknown(type)
            accumulator.emit(payload: unknownPayload(rawKind: type, summary: "Unknown Codex record: \(type)", raw: line), journalID: journalID, lineIndex: lineIndex)
        }
    }

    private mutating func decodeSessionMeta(
        _ root: [String: JSONValue],
        raw: String,
        lineIndex: Int,
        journalID: JournalID,
        accumulator: inout TranscriptDecodeAccumulator
    ) {
        let payload = root["payload"]?.object ?? root
        let version = payload["cli_version"]?.string ?? "unknown"
        if version != "unknown" {
            accumulator.recordCLIVersion(version)
        }
        accumulator.emit(payload: .status(StatusPayload(code: .sessionMeta, detail: "Codex session \(version)")), journalID: journalID, lineIndex: lineIndex)
    }

    private mutating func decodeEventMessage(
        _ payload: [String: JSONValue],
        raw: String,
        lineIndex: Int,
        journalID: JournalID,
        accumulator: inout TranscriptDecodeAccumulator
    ) {
        let eventType = payload["type"]?.string ?? "event"
        switch eventType {
        case "turn_aborted":
            accumulator.recordPhaseFact(.turnAborted(line: lineIndex))
            accumulator.countModeled("event_msg.\(eventType)")
            accumulator.emit(payload: .status(StatusPayload(code: .turnAborted, detail: "Turn aborted")), journalID: journalID, lineIndex: lineIndex)
        case "task_started":
            accumulator.recordPhaseFact(.taskStarted(line: lineIndex))
            accumulator.countModeled("event_msg.\(eventType)")
        case "task_complete":
            accumulator.recordPhaseFact(.taskCompleted(line: lineIndex))
            accumulator.countModeled("event_msg.\(eventType)")
        case "context_compacted", "compacted", "compact_complete":
            accumulator.countModeled("event_msg.\(eventType)")
            // The `compacted` record is the authoritative row when both streams
            // describe the same compaction, so a later event duplicate is kept
            // diagnostic-only.
            if !sawCompactedRecord {
                accumulator.emit(payload: .status(StatusPayload(code: .compacted, detail: "Context compacted")), journalID: journalID, lineIndex: lineIndex)
            }
        case "user_message", "agent_message":
            accumulator.countDuplicateStream("event_msg.\(eventType)")
        case "patch_apply_end", "web_search_end", "mcp_tool_call_end", "entered_review_mode", "exited_review_mode", "thread_goal_updated", "thread_rolled_back", "token_count":
            accumulator.countModeled("event_msg.\(eventType)")
        default:
            accumulator.countUnknown("event_msg.\(eventType)")
        }
    }

    private func decodeTurnContext(
        _ payload: [String: JSONValue],
        lineIndex: Int,
        accumulator: inout TranscriptDecodeAccumulator
    ) {
        accumulator.countModeled("turn_context")
        accumulator.recordTurnContextFact(TurnContextFact(
            line: lineIndex,
            model: payload["model"]?.string,
            sandboxPolicy: sandboxPolicy(in: payload),
            approvalPolicy: payload["approval_policy"]?.string
        ))
    }

    private func sandboxPolicy(in payload: [String: JSONValue]) -> String? {
        payload["sandbox_policy"]?.object?["type"]?.string
            ?? payload["sandbox_policy"]?.string
            ?? payload["sandbox"]?.string
            ?? payload["sandbox_mode"]?.string
    }

    private mutating func decodeResponseItem(
        _ payload: [String: JSONValue],
        raw: String,
        lineIndex: Int,
        journalID: JournalID,
        accumulator: inout TranscriptDecodeAccumulator
    ) {
        guard let itemType = payload["type"]?.string else {
            accumulator.countUnknown("missing_response_item_type")
            accumulator.emit(payload: unknownPayload(rawKind: "missing_response_item_type", summary: "Missing Codex response item type", raw: raw), journalID: journalID, lineIndex: lineIndex)
            return
        }
        switch itemType {
        case "message":
            decodeMessage(payload, raw: raw, lineIndex: lineIndex, journalID: journalID, accumulator: &accumulator)
        case "reasoning":
            accumulator.emit(payload: .thought(ThoughtPayload(text: payload["summary"]?.textFragments().joined(separator: "\n") ?? payload["content"]?.textFragments().joined(separator: "\n") ?? "")), journalID: journalID, lineIndex: lineIndex)
        case "function_call":
            decodeFunctionCall(payload, raw: raw, lineIndex: lineIndex, journalID: journalID, accumulator: &accumulator)
        case "function_call_output":
            decodeFunctionOutput(payload, raw: raw, lineIndex: lineIndex, journalID: journalID, accumulator: &accumulator)
        case "custom_tool_call", "web_search_call", "tool_search_call":
            decodeFunctionCall(payload, raw: raw, lineIndex: lineIndex, journalID: journalID, accumulator: &accumulator)
        case "custom_tool_call_output", "tool_search_output":
            decodeFunctionOutput(payload, raw: raw, lineIndex: lineIndex, journalID: journalID, accumulator: &accumulator)
        default:
            accumulator.countUnknown(itemType)
            accumulator.emit(payload: unknownPayload(rawKind: itemType, summary: "Unknown Codex response item: \(itemType)", raw: raw), journalID: journalID, lineIndex: lineIndex)
        }
    }

    private mutating func decodeMessage(
        _ payload: [String: JSONValue],
        raw: String,
        lineIndex: Int,
        journalID: JournalID,
        accumulator: inout TranscriptDecodeAccumulator
    ) {
        let role = payload["role"]?.string ?? "assistant"
        let text = payload["content"]?.textFragments().joined(separator: "\n") ?? ""
        let entryPayload: EntryPayload = if role == "user" {
            .userMessage(UserMessagePayload(text: text, attachmentCount: attachmentCount(in: payload["content"]), hasImage: hasImage(in: payload["content"])))
        } else {
            .agentProse(AgentProsePayload(markdown: text))
        }
        accumulator.emit(payload: entryPayload, journalID: journalID, lineIndex: lineIndex)
    }

    private mutating func decodeFunctionCall(
        _ payload: [String: JSONValue],
        raw: String,
        lineIndex: Int,
        journalID: JournalID,
        accumulator: inout TranscriptDecodeAccumulator
    ) {
        let itemType = payload["type"]?.string
        let name = payload["name"]?.string ?? toolName(for: itemType) ?? payload["call_id"]?.string ?? "call"
        let argumentValue = payload["arguments"] ?? payload["input"] ?? payload["action"]
        let argumentSummary = summarizeArguments(argumentValue)
        let entryPayload: EntryPayload = if name == "apply_patch" {
            .fileChange(FileChangePayload(path: filePath(in: argumentValue) ?? "", changeKind: .patch))
        } else {
            .toolRun(ToolRunPayload(
                toolName: name,
                argumentSummary: argumentSummary,
                isTerminal: isTerminalTool(name: name, arguments: argumentValue),
                isRunning: true
            ))
        }
        if let callID = payload["call_id"]?.string {
            pendingCalls[callID] = PendingToolUse(payload: entryPayload, raw: raw)
        }
        accumulator.emit(payload: entryPayload, journalID: journalID, lineIndex: lineIndex)
    }

    private mutating func decodeFunctionOutput(
        _ payload: [String: JSONValue],
        raw: String,
        lineIndex: Int,
        journalID: JournalID,
        accumulator: inout TranscriptDecodeAccumulator
    ) {
        let outputType = payload["type"]?.string ?? "function_call_output"
        guard let callID = payload["call_id"]?.string, let pending = pendingCalls.removeValue(forKey: callID) else {
            accumulator.countUnknown(outputType)
            accumulator.emit(payload: unknownPayload(rawKind: outputType, summary: "Unpaired Codex \(outputType)", raw: raw), journalID: journalID, lineIndex: lineIndex)
            return
        }
        let output = payload["output"]?.textFragments().joined(separator: "\n") ?? ""
        accumulator.emit(payload: payloadByAddingResult(pending.payload, resultSummary: output, exitCode: exitCode(in: payload)), journalID: journalID, lineIndex: lineIndex)
    }

    private func toolName(for itemType: String?) -> String? {
        switch itemType {
        case "tool_search_call":
            "tool_search"
        case "web_search_call":
            "web_search"
        default:
            nil
        }
    }

    private func summarizeArguments(_ value: JSONValue?) -> String {
        guard let value else {
            return ""
        }
        if let string = value.string {
            return summarizeArgumentValue(lineDecoder.decode(string) ?? .string(string))
        }
        return summarizeArgumentValue(value)
    }

    private func summarizeArgumentValue(_ value: JSONValue) -> String {
        if let object = value.object {
            if let command = object["command"] {
                return summarizeCommand(command)
            }
            if let cmd = object["cmd"]?.string {
                return cmd
            }
            if let query = object["query"]?.string {
                return query
            }
        }
        return summarizeCommand(value)
    }

    private func summarizeCommand(_ value: JSONValue) -> String {
        if let command = value.string {
            return command
        }
        guard let array = value.array else {
            return value.textFragments().joined(separator: " ")
        }
        let parts = array.compactMap(\.string)
        if parts.count >= 3, parts[0] == "bash", parts[1] == "-lc" {
            return parts[2]
        }
        return parts.joined(separator: " ")
    }

    private func unknownPayload(rawKind: String, summary: String, raw: String) -> EntryPayload {
        .unknown(UnknownPayload(rawKind: rawKind, summary: summary, rawJSON: raw))
    }

    private func attachmentCount(in value: JSONValue?) -> Int {
        value?.array?.filter { item in
            guard let type = item.object?["type"]?.string else {
                return false
            }
            return type.contains("image") || type.contains("attachment")
        }.count ?? 0
    }

    private func hasImage(in value: JSONValue?) -> Bool {
        attachmentCount(in: value) > 0
    }

    private func isTerminalTool(name: String, arguments: JSONValue?) -> Bool {
        let lowercased = name.lowercased()
        if lowercased == "bash" || lowercased == "shell" || lowercased == "terminal" {
            return true
        }
        guard let executable = parsedCommandArray(in: arguments)?.first?.string else {
            return false
        }
        let executableName = executable.split(separator: "/").last?.lowercased() ?? executable.lowercased()
        return executableName == "bash" || executableName == "sh" || executableName == "zsh" || executableName == "fish"
    }

    private func parsedCommandArray(in arguments: JSONValue?) -> [JSONValue]? {
        let parsedArguments: JSONValue?
        if let encodedArguments = arguments?.string {
            parsedArguments = lineDecoder.decode(encodedArguments)
        } else {
            parsedArguments = arguments
        }
        return parsedArguments?.object?["command"]?.array ?? parsedArguments?.array
    }

    private func filePath(in value: JSONValue?) -> String? {
        let object: [String: JSONValue]?
        if let string = value?.string {
            object = lineDecoder.decode(string)?.object
        } else {
            object = value?.object
        }
        return object?["file_path"]?.string
            ?? object?["path"]?.string
            ?? object?["target_file"]?.string
    }

    private func exitCode(in payload: [String: JSONValue]) -> Int? {
        payload["exit_code"]?.int
            ?? payload["exitCode"]?.int
            ?? payload["status_code"]?.int
            ?? payload["statusCode"]?.int
    }

    private func payloadByAddingResult(_ payload: EntryPayload, resultSummary: String, exitCode: Int?) -> EntryPayload {
        switch payload {
        case .toolRun(let tool):
            .toolRun(ToolRunPayload(
                toolName: tool.toolName,
                argumentSummary: tool.argumentSummary,
                resultSummary: resultSummary,
                isTerminal: tool.isTerminal,
                exitCode: exitCode,
                isRunning: false
            ))
        case .fileChange(let file):
            .fileChange(FileChangePayload(path: file.path, changeKind: file.changeKind, resultSummary: resultSummary))
        default:
            payload
        }
    }
}
