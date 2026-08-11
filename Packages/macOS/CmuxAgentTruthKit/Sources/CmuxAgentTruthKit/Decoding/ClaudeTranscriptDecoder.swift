public import CmuxAgentReplica
import Foundation

/// Decodes Claude Code project JSONL transcripts into fail-open entries.
///
/// Claude records can contain multiple content blocks on one JSONL line. This
/// decoder emits exactly one ``EntrySnapshot`` per source line; summaries are
/// joined in source order and the dominant kind is chosen by display impact:
/// question, file change, tool run, thought, prose/message, then unknown.
/// A `tool_result` without a numeric exit code synthesizes
/// ``ToolRunPayload/exitCode`` from `is_error`: `false` maps to `0` and `true`
/// maps to `1`, including for non-shell tools.
public struct ClaudeTranscriptDecoder: TranscriptDecoder, Sendable {
    private let lineDecoder: JSONLineDecoder
    private let textBudget: TranscriptTextBudget
    private var pendingTools: [String: PendingToolUse]

    /// Creates a Claude transcript decoder.
    public init() {
        self.lineDecoder = JSONLineDecoder()
        self.textBudget = TranscriptTextBudget()
        self.pendingTools = [:]
    }

    /// Feeds Claude transcript lines at their absolute line index.
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
        if root["isApiErrorMessage"]?.bool == true {
            accumulator.recordAPIError()
        }
        guard let recordType = root["type"]?.string else {
            accumulator.countUnknown("missing_type")
            accumulator.emit(payload: unknownPayload(rawKind: "missing_type", summary: "Missing Claude record type", raw: line), journalID: journalID, lineIndex: lineIndex)
            return
        }
        if decodeBookkeepingRecord(root, recordType: recordType, lineIndex: lineIndex, accumulator: &accumulator) {
            return
        }
        if root["isSidechain"]?.bool == true || root["isMeta"]?.bool == true {
            accumulator.countModeled(root["isMeta"]?.bool == true ? "meta" : "sidechain")
            return
        }
        switch recordType {
        case "user", "assistant":
            decodeMessageRecord(root, roleHint: recordType, raw: line, lineIndex: lineIndex, journalID: journalID, accumulator: &accumulator)
        case "system":
            decodeSystemRecord(root, raw: line, lineIndex: lineIndex, journalID: journalID, accumulator: &accumulator)
        case "summary":
            accumulator.countUnknown(recordType)
        default:
            accumulator.countUnknown(recordType)
            accumulator.emit(payload: unknownPayload(rawKind: recordType, summary: "Unknown Claude record: \(recordType)", raw: line), journalID: journalID, lineIndex: lineIndex)
        }
    }

    private func decodeBookkeepingRecord(
        _ root: [String: JSONValue],
        recordType: String,
        lineIndex: Int,
        accumulator: inout TranscriptDecodeAccumulator
    ) -> Bool {
        guard bookkeepingRecordTypes.contains(recordType) else {
            return false
        }
        accumulator.countBookkeeping(recordType)
        if let title = sensitiveTitleValue(in: root, recordType: recordType) {
            accumulator.recordSensitiveSessionTitle(SensitiveSessionTitleFact(line: lineIndex, source: recordType, sensitiveValue: title))
        }
        return true
    }

    private func decodeSystemRecord(
        _ root: [String: JSONValue],
        raw: String,
        lineIndex: Int,
        journalID: JournalID,
        accumulator: inout TranscriptDecodeAccumulator
    ) {
        let subtype = root["subtype"]?.string ?? "system"
        accumulator.countModeled("system.\(subtype)")
        if subtype == "api_error" || root["isApiErrorMessage"]?.bool == true {
            accumulator.recordAPIError()
        }
        // System records with user-visible failure/progress content emit status
        // rows. Pure telemetry subtypes are modeled diagnostics only.
        if systemTelemetrySubtypes.contains(subtype) {
            return
        }
        let code: StatusCode = subtype == "api_error" ? .apiError : .other(subtype)
        accumulator.emit(payload: .status(StatusPayload(code: code, detail: "System \(subtype)")), journalID: journalID, lineIndex: lineIndex)
    }

    private mutating func decodeMessageRecord(
        _ root: [String: JSONValue],
        roleHint: String,
        raw: String,
        lineIndex: Int,
        journalID: JournalID,
        accumulator: inout TranscriptDecodeAccumulator
    ) {
        let message = root["message"]?.object
        let role = message?["role"]?.string ?? roleHint
        guard let content = message?["content"] ?? root["content"] else {
            accumulator.countUnknown("missing_content")
            accumulator.emit(payload: unknownPayload(rawKind: "missing_content", summary: "Missing Claude content", raw: raw), journalID: journalID, lineIndex: lineIndex)
            return
        }
        if let text = content.string {
            let payload: EntryPayload = role == "user"
                ? .userMessage(UserMessagePayload(text: textBudget.body(text), attachmentCount: 0, hasImage: false))
                : .agentProse(AgentProsePayload(markdown: textBudget.body(text)))
            accumulator.emit(payload: payload, journalID: journalID, lineIndex: lineIndex)
            return
        }
        guard let blocks = content.array else {
            accumulator.countUnknown("content")
            accumulator.emit(payload: unknownPayload(rawKind: "content", summary: "Unknown Claude content shape", raw: raw), journalID: journalID, lineIndex: lineIndex)
            return
        }
        var decodedBlocks: [ClaudeDecodedBlock] = []
        for block in blocks {
            if let decoded = decodeBlock(block, role: role, raw: raw, accumulator: &accumulator) {
                decodedBlocks.append(decoded)
            }
        }
        guard !decodedBlocks.isEmpty else {
            return
        }
        accumulator.emit(payload: combinedPayload(from: decodedBlocks), journalID: journalID, lineIndex: lineIndex)
    }

    private mutating func decodeBlock(
        _ block: JSONValue,
        role: String,
        raw: String,
        accumulator: inout TranscriptDecodeAccumulator
    ) -> ClaudeDecodedBlock? {
        guard let object = block.object, let type = object["type"]?.string else {
            accumulator.countUnknown("block")
            return ClaudeDecodedBlock(summary: "Unknown Claude block", payload: .unknown(UnknownPayload(rawKind: "block", summary: "Unknown Claude block", rawJSON: raw)))
        }
        switch type {
        case "text":
            let text = object["text"]?.string ?? ""
            let payload: EntryPayload = role == "user"
                ? .userMessage(UserMessagePayload(text: textBudget.body(text), attachmentCount: 0, hasImage: false))
                : .agentProse(AgentProsePayload(markdown: textBudget.body(text)))
            return ClaudeDecodedBlock(summary: text, payload: payload)
        case "image":
            let payload: EntryPayload = role == "user"
                ? .userMessage(UserMessagePayload(text: "Image attachment", attachmentCount: 1, hasImage: true))
                : .attachment(AttachmentPayload(kind: "image", summary: "Image attachment"))
            return ClaudeDecodedBlock(summary: "Image attachment", payload: payload)
        case "thinking":
            let text = object["thinking"]?.string ?? object["text"]?.string ?? ""
            let bounded = textBudget.body(text)
            return ClaudeDecodedBlock(summary: bounded, payload: .thought(ThoughtPayload(text: bounded)))
        case "tool_use":
            return decodeToolUse(object, raw: raw)
        case "tool_result":
            return decodeToolResult(object, accumulator: &accumulator)
        default:
            accumulator.countUnknown(type)
            return ClaudeDecodedBlock(summary: "Unknown Claude block: \(type)", payload: .unknown(UnknownPayload(rawKind: type, summary: "Unknown Claude block: \(type)", rawJSON: raw)))
        }
    }

    private mutating func decodeToolUse(
        _ object: [String: JSONValue],
        raw: String
    ) -> ClaudeDecodedBlock {
        let toolName = object["name"]?.string ?? "unknown"
        let input = object["input"]
        let payload = payloadForToolUse(name: toolName, input: input)
        if let id = object["id"]?.string {
            pendingTools[id] = PendingToolUse(payload: payload, raw: raw)
        }
        return ClaudeDecodedBlock(summary: summary(for: payload), payload: payload)
    }

    private mutating func decodeToolResult(
        _ object: [String: JSONValue],
        accumulator: inout TranscriptDecodeAccumulator
    ) -> ClaudeDecodedBlock {
        guard let id = object["tool_use_id"]?.string, let pending = pendingTools.removeValue(forKey: id) else {
            accumulator.countUnknown("tool_result")
            return ClaudeDecodedBlock(summary: "Unpaired Claude tool result", payload: .unknown(UnknownPayload(rawKind: "tool_result", summary: "Unpaired Claude tool result")))
        }
        let fragments = textBudget.body(object["content"]?.textFragments().joined(separator: "\n") ?? "")
        let payload = payloadByAddingResult(pending.payload, resultSummary: fragments, exitCode: exitCode(in: object))
        return ClaudeDecodedBlock(summary: summary(for: payload), payload: payload)
    }

    private func payloadForToolUse(name: String, input: JSONValue?) -> EntryPayload {
        switch name {
        case "Write":
            .fileChange(FileChangePayload(path: textBudget.inputDetail(filePath(in: input) ?? ""), changeKind: .write))
        case "Edit", "MultiEdit":
            .fileChange(FileChangePayload(path: textBudget.inputDetail(filePath(in: input) ?? ""), changeKind: .edit))
        case "NotebookEdit":
            .fileChange(FileChangePayload(path: textBudget.inputDetail(filePath(in: input) ?? ""), changeKind: .notebook))
        case "AskUserQuestion":
            .question(QuestionPayload(prompt: questionPrompt(in: input), options: questionOptions(in: input)))
        case "Bash":
            .toolRun(ToolRunPayload(toolName: name, argumentSummary: textBudget.inputDetail(commandSummary(in: input)), isTerminal: true, isRunning: true))
        default:
            .toolRun(ToolRunPayload(toolName: name, argumentSummary: textBudget.inputDetail(commandSummary(in: input)), isTerminal: false, isRunning: true))
        }
    }

    private func dominantKind(in blocks: [ClaudeDecodedBlock]) -> EntryKind {
        blocks.min { lhs, rhs in
            priority(for: lhs.kind) < priority(for: rhs.kind)
        }?.kind ?? .unknown("empty")
    }

    private func combinedPayload(from blocks: [ClaudeDecodedBlock]) -> EntryPayload {
        let kind = dominantKind(in: blocks)
        switch kind {
        case .userMessage:
            let userPayloads = blocks.compactMap { block -> UserMessagePayload? in
                if case .userMessage(let payload) = block.payload {
                    return payload
                }
                return nil
            }
            return .userMessage(UserMessagePayload(
                text: blocks.map(\.summary).filter { !$0.isEmpty }.joined(separator: "\n"),
                attachmentCount: userPayloads.map(\.attachmentCount).reduce(0, +),
                hasImage: userPayloads.contains { $0.hasImage }
            ))
        case .agentProse:
            return .agentProse(AgentProsePayload(markdown: blocks.map(\.summary).filter { !$0.isEmpty }.joined(separator: "\n")))
        default:
            return blocks.first { $0.kind == kind }?.payload ?? .unknown(UnknownPayload(rawKind: "empty"))
        }
    }

    private func priority(for kind: EntryKind) -> Int {
        switch kind {
        case .question:
            0
        case .fileChange:
            1
        case .toolRun:
            2
        case .thought:
            3
        case .agentProse, .userMessage:
            4
        case .unknown:
            5
        case .permission:
            0
        case .status, .attachment:
            6
        }
    }

    private var bookkeepingRecordTypes: Set<String> {
        [
            "ai-title",
            "custom-title",
            "agent-name",
            "last-prompt",
            "mode",
            "permission-mode",
            "pr-link",
            "queue-operation",
            "bridge-session",
            "file-history-snapshot",
            "attachment",
        ]
    }

    private var systemTelemetrySubtypes: Set<String> {
        [
            "turn_duration",
        ]
    }

    private func sensitiveTitleValue(in root: [String: JSONValue], recordType: String) -> String? {
        switch recordType {
        case "ai-title":
            root["aiTitle"]?.string
        case "custom-title":
            root["customTitle"]?.string
        case "agent-name":
            root["agentName"]?.string
        default:
            nil
        }
    }

    private func unknownPayload(rawKind: String, summary: String, raw: String) -> EntryPayload {
        .unknown(UnknownPayload(rawKind: rawKind, summary: summary, rawJSON: raw))
    }

    private func commandSummary(in input: JSONValue?) -> String {
        guard let input else {
            return ""
        }
        if let command = input.object?["command"]?.string {
            return command
        }
        if let command = input.object?["command"]?.array?.compactMap(\.string).joined(separator: " ") {
            return command
        }
        return input.textFragments().joined(separator: " ")
    }

    private func filePath(in input: JSONValue?) -> String? {
        input?.object?["file_path"]?.string
            ?? input?.object?["path"]?.string
            ?? input?.object?["notebook_path"]?.string
    }

    private func questionPrompt(in input: JSONValue?) -> String {
        input?.object?["question"]?.string
            ?? input?.object?["prompt"]?.string
            ?? commandSummary(in: input)
    }

    private func questionOptions(in input: JSONValue?) -> [String] {
        input?.object?["options"]?.array?.compactMap(\.string) ?? []
    }

    private func exitCode(in object: [String: JSONValue]) -> Int? {
        if let exitCode = object["exit_code"]?.int ?? object["exitCode"]?.int {
            return exitCode
        }
        if let isError = object["is_error"]?.bool {
            return isError ? 1 : 0
        }
        return nil
    }

    private func payloadByAddingResult(_ payload: EntryPayload, resultSummary: String, exitCode: Int?) -> EntryPayload {
        switch payload {
        case .toolRun(let tool):
            .toolRun(ToolRunPayload(
                toolName: tool.toolName,
                argumentSummary: tool.argumentSummary,
                resultSummary: textBudget.body(resultSummary),
                isTerminal: tool.isTerminal,
                exitCode: exitCode,
                isRunning: false
            ))
        case .fileChange(let file):
            .fileChange(FileChangePayload(path: file.path, changeKind: file.changeKind, resultSummary: textBudget.body(resultSummary)))
        default:
            payload
        }
    }

    private func summary(for payload: EntryPayload) -> String {
        switch payload {
        case .toolRun(let tool):
            [tool.toolName, tool.argumentSummary, tool.resultSummary].compactMap { value in
                guard let value, !value.isEmpty else {
                    return nil
                }
                return value
            }.joined(separator: " ")
        case .fileChange(let file):
            [file.path, file.resultSummary].compactMap { value in
                guard let value, !value.isEmpty else {
                    return nil
                }
                return value
            }.joined(separator: " ")
        case .question(let question):
            question.prompt
        case .unknown(let unknown):
            unknown.summary ?? unknown.rawKind
        default:
            ""
        }
    }
}
