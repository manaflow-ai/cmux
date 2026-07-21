public import CmuxAgentReplica
import Foundation

/// Decodes Codex rollout JSONL transcripts into fail-open entries.
public struct CodexTranscriptDecoder: TranscriptDecoder, Sendable {
    private let lineDecoder: JSONLineDecoder
    private let textBudget: TranscriptTextBudget
    private var pendingCalls: [String: PendingToolUse]
    private var seenQuestionCallIDs: Set<String>
    private var sawCompactedRecord: Bool

    /// Creates a Codex transcript decoder.
    public init() {
        self.lineDecoder = JSONLineDecoder()
        self.textBudget = TranscriptTextBudget()
        self.pendingCalls = [:]
        self.seenQuestionCallIDs = []
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
        accumulator.beginSourceLine(timestampMilliseconds: nil)
        guard let root = lineDecoder.decode(line)?.object else {
            accumulator.countUnknown("malformed")
            accumulator.emit(payload: unknownPayload(rawKind: "malformed", summary: "Malformed transcript line", raw: line), journalID: journalID, lineIndex: lineIndex)
            return
        }
        accumulator.beginSourceLine(timestampMilliseconds: TranscriptTimestampParser.milliseconds(root["timestamp"]))
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
        case "request_user_input":
            decodeRequestUserInput(
                payload,
                callID: payload["call_id"]?.string,
                lineIndex: lineIndex,
                journalID: journalID,
                accumulator: &accumulator
            )
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
            let text = payload["summary"]?.textFragments().joined(separator: "\n")
                ?? payload["content"]?.textFragments().joined(separator: "\n")
                ?? ""
            accumulator.emit(payload: .thought(ThoughtPayload(text: textBudget.body(text))), journalID: journalID, lineIndex: lineIndex)
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
            .userMessage(UserMessagePayload(text: textBudget.body(text), attachmentCount: attachmentCount(in: payload["content"]), hasImage: hasImage(in: payload["content"])))
        } else {
            .agentProse(AgentProsePayload(markdown: textBudget.body(text)))
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
        let callID = payload["call_id"]?.string
        let argumentValue = payload["arguments"] ?? payload["input"] ?? payload["action"]
        let argumentSummary = summarizeArguments(argumentValue)
        if name == "request_user_input" {
            let callID = payload["call_id"]?.string
            let question = requestUserInputQuestion(in: argumentValue)
            if let callID, let question {
                pendingCalls[callID] = PendingToolUse(payload: .question(question), raw: raw)
            }
            decodeRequestUserInput(
                parsedRequestUserInput(in: argumentValue)?.object ?? [:],
                callID: callID,
                lineIndex: lineIndex,
                journalID: journalID,
                accumulator: &accumulator
            )
            return
        }
        let entryPayload: EntryPayload
        if name == "apply_patch" {
            entryPayload = .fileChange(fileChangePayload(arguments: argumentValue, toolCallID: callID))
        } else {
            let terminal = isTerminalTool(name: name, arguments: argumentValue)
            entryPayload = .toolRun(ToolRunPayload(
                toolName: name,
                argumentSummary: textBudget.summaryArgument(argumentSummary),
                isTerminal: terminal,
                isRunning: true,
                toolCallID: callID,
                inputDetail: textBudget.inputDetail(rendered(argumentValue)),
                command: terminal ? textBudget.inputDetail(command(in: argumentValue)) : nil,
                status: payload["status"]?.string ?? "running"
            ))
        }
        if let callID {
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
        let callID = payload["call_id"]?.string
        let output = textBudget.body(
            payload["output"]?.textFragments().joined(separator: "\n")
                ?? rendered(payload["tools"])
        )
        let exitCode = exitCode(in: payload)
        let duration = durationSeconds(in: payload)
        let reportedStatus = payload["status"]?.string
            ?? (exitCode.map { $0 == 0 ? "succeeded" : "failed" } ?? "completed")
        guard let callID, let pending = pendingCalls.removeValue(forKey: callID) else {
            accumulator.countUnknown(outputType)
            accumulator.emit(
                payload: .toolRun(ToolRunPayload(
                    toolName: "Unknown tool",
                    argumentSummary: "Missing invocation metadata",
                    resultSummary: output,
                    isTerminal: false,
                    exitCode: exitCode,
                    isRunning: false,
                    toolCallID: callID,
                    output: output,
                    durationSeconds: duration,
                    status: "unpaired_result:\(reportedStatus)"
                )),
                journalID: journalID,
                lineIndex: lineIndex
            )
            return
        }
        if case .question = pending.payload {
            accumulator.countModeled("request_user_input.output")
            return
        }
        accumulator.emit(
            payload: payloadByAddingResult(
                pending.payload,
                resultSummary: output,
                exitCode: exitCode,
                durationSeconds: duration,
                status: reportedStatus
            ),
            journalID: journalID,
            lineIndex: lineIndex
        )
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

    private func parsedRequestUserInput(in value: JSONValue?) -> JSONValue? {
        if let encoded = value?.string {
            return lineDecoder.decode(encoded)
        }
        return value
    }

    private func requestUserInputQuestion(in value: JSONValue?) -> QuestionPayload? {
        questionPayload(in: parsedRequestUserInput(in: value)?.object ?? [:])
    }

    private mutating func decodeRequestUserInput(
        _ payload: [String: JSONValue],
        callID: String?,
        lineIndex: Int,
        journalID: JournalID,
        accumulator: inout TranscriptDecodeAccumulator
    ) {
        if let callID, !seenQuestionCallIDs.insert(callID).inserted {
            accumulator.countDuplicateStream("request_user_input")
            return
        }
        guard let question = questionPayload(in: payload) else {
            accumulator.countUnknown("request_user_input")
            return
        }
        accumulator.emit(payload: .question(question), journalID: journalID, lineIndex: lineIndex)
    }

    private func questionPayload(in payload: [String: JSONValue]) -> QuestionPayload? {
        guard let questions = payload["questions"]?.array, !questions.isEmpty else {
            return nil
        }
        guard questions.count == 1,
              let question = questions.first?.object,
              let prompt = question["question"]?.string else {
            let prompts = questions.compactMap { value -> String? in
                guard let object = value.object, let prompt = object["question"]?.string else { return nil }
                if let header = object["header"]?.string, !header.isEmpty {
                    return "\(header): \(prompt)"
                }
                return prompt
            }
            guard !prompts.isEmpty else { return nil }
            return QuestionPayload(prompt: prompts.joined(separator: "\n"), options: [])
        }
        let options = question["options"]?.array?.compactMap { option in
            option.object?["label"]?.string ?? option.string
        } ?? []
        let indexedOptions = options.count <= 9 ? options : []
        return QuestionPayload(
            questionID: question["id"]?.string,
            header: question["header"]?.string,
            prompt: prompt,
            options: indexedOptions
        )
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

    private func payloadByAddingResult(
        _ payload: EntryPayload,
        resultSummary: String,
        exitCode: Int?,
        durationSeconds: Double?,
        status: String?
    ) -> EntryPayload {
        let boundedResult = textBudget.body(resultSummary)
        return switch payload {
        case .toolRun(let tool):
            .toolRun(ToolRunPayload(
                toolName: tool.toolName,
                argumentSummary: tool.argumentSummary,
                resultSummary: boundedResult,
                isTerminal: tool.isTerminal,
                exitCode: exitCode,
                isRunning: false,
                toolCallID: tool.toolCallID,
                inputDetail: tool.inputDetail,
                command: tool.command,
                output: boundedResult,
                durationSeconds: durationSeconds,
                status: status
            ))
        case .fileChange(let file):
            .fileChange(FileChangePayload(
                path: file.path,
                changeKind: file.changeKind,
                resultSummary: boundedResult,
                toolCallID: file.toolCallID,
                oldPath: file.oldPath,
                newPath: file.newPath,
                additions: file.additions,
                deletions: file.deletions,
                unifiedDiff: file.unifiedDiff
            ))
        default:
            payload
        }
    }

    private func rendered(_ value: JSONValue?) -> String {
        guard let value else { return "" }
        if let string = value.string { return string }
        guard let data = try? JSONEncoder().encode(value) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    private func command(in value: JSONValue?) -> String {
        let parsed: JSONValue?
        if let string = value?.string {
            parsed = lineDecoder.decode(string) ?? value
        } else {
            parsed = value
        }
        guard let parsed else { return "" }
        if let command = parsed.object?["cmd"]?.string {
            return command
        }
        if let command = parsed.object?["command"] {
            return summarizeCommand(command)
        }
        return summarizeCommand(parsed)
    }

    private func fileChangePayload(arguments: JSONValue?, toolCallID: String?) -> FileChangePayload {
        let patch = rendered(arguments)
        let paths = patchPaths(in: patch)
        let counts = patchLineCounts(in: patch)
        return FileChangePayload(
            path: textBudget.inputDetail(filePath(in: arguments) ?? paths.new ?? paths.old ?? ""),
            changeKind: .patch,
            toolCallID: toolCallID,
            oldPath: paths.old,
            newPath: paths.new,
            additions: counts.additions,
            deletions: counts.deletions,
            unifiedDiff: patch.isEmpty ? nil : textBudget.body(patch)
        )
    }

    private func patchPaths(in patch: String) -> (old: String?, new: String?) {
        var oldPath: String?
        var newPath: String?
        for line in patch.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("*** Update File: ") {
                let path = String(line.dropFirst("*** Update File: ".count))
                oldPath = path
                newPath = path
            } else if line.hasPrefix("*** Add File: ") {
                newPath = String(line.dropFirst("*** Add File: ".count))
            } else if line.hasPrefix("*** Delete File: ") {
                oldPath = String(line.dropFirst("*** Delete File: ".count))
            } else if line.hasPrefix("--- "), oldPath == nil {
                oldPath = String(line.dropFirst(4))
            } else if line.hasPrefix("+++ "), newPath == nil {
                newPath = String(line.dropFirst(4))
            }
        }
        return (oldPath, newPath)
    }

    private func patchLineCounts(in patch: String) -> (additions: Int?, deletions: Int?) {
        guard !patch.isEmpty else { return (nil, nil) }
        var additions = 0
        var deletions = 0
        for line in patch.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("+") && !line.hasPrefix("+++") {
                additions += 1
            } else if line.hasPrefix("-") && !line.hasPrefix("---") {
                deletions += 1
            }
        }
        return (additions, deletions)
    }

    private func durationSeconds(in payload: [String: JSONValue]) -> Double? {
        payload["duration_seconds"]?.number
            ?? payload["durationSeconds"]?.number
            ?? payload["duration_ms"]?.number.map { $0 / 1_000 }
            ?? payload["durationMs"]?.number.map { $0 / 1_000 }
    }
}
