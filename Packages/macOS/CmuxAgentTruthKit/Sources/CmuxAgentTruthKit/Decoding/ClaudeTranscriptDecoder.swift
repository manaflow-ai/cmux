public import CmuxAgentReplica
import Foundation

/// Decodes Claude Code project JSONL transcripts into fail-open entries.
///
/// Claude records can contain multiple content blocks on one JSONL line. This
/// decoder preserves every user-visible block as an independently pairable
/// entry in source order.
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
        accumulator.beginSourceLine(timestampMilliseconds: nil)
        guard let root = lineDecoder.decode(line)?.object else {
            accumulator.countUnknown("malformed")
            accumulator.emit(payload: unknownPayload(rawKind: "malformed", summary: "Malformed transcript line", raw: line), journalID: journalID, lineIndex: lineIndex)
            return
        }
        accumulator.beginSourceLine(timestampMilliseconds: TranscriptTimestampParser.milliseconds(root["timestamp"]))
        if root["isApiErrorMessage"]?.bool == true {
            accumulator.recordAPIError()
        }
        guard let recordType = root["type"]?.string else {
            accumulator.countUnknown("missing_type")
            accumulator.emit(payload: unknownPayload(rawKind: "missing_type", summary: "Missing Claude record type", raw: line), journalID: journalID, lineIndex: lineIndex)
            return
        }
        if recordType == "attachment" {
            accumulator.countBookkeeping(recordType)
            let attachment = root["attachment"]?.object ?? root
            accumulator.emit(
                payload: .attachment(attachmentPayload(in: attachment)),
                journalID: journalID,
                lineIndex: lineIndex
            )
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
        var embeddedImagesByOrdinal: [Int: TranscriptEmbeddedImageSource] = [:]
        for (ordinal, block) in decodedBlocks.enumerated() {
            if let embeddedImage = block.embeddedImage {
                embeddedImagesByOrdinal[ordinal] = embeddedImage
            }
        }
        accumulator.emit(
            payloads: decodedBlocks.map(\.payload),
            embeddedImagesByOrdinal: embeddedImagesByOrdinal,
            journalID: journalID,
            lineIndex: lineIndex
        )
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
            let source = object["source"]?.object
            let mimeType = source?["media_type"]?.string ?? object["media_type"]?.string
            let base64EncodedData = source?["data"]?.string
            let attachment = AttachmentPayload(
                kind: "image",
                summary: "Image attachment",
                attachmentID: object["id"]?.string,
                displayName: object["file_name"]?.string ?? object["fileName"]?.string,
                hostPath: source?["path"]?.string ?? object["path"]?.string,
                mimeType: mimeType,
                byteCount: base64EncodedData.map(estimatedDecodedByteCount),
                width: object["width"]?.int,
                height: object["height"]?.int
            )
            return ClaudeDecodedBlock(
                summary: "Image attachment",
                payload: .attachment(attachment),
                embeddedImage: base64EncodedData.map {
                    TranscriptEmbeddedImageSource(
                        mimeType: mimeType,
                        base64EncodedData: $0
                    )
                }
            )
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
        let id = object["id"]?.string
        let payload = payloadForToolUse(name: toolName, input: input, toolCallID: id)
        if let id {
            pendingTools[id] = PendingToolUse(payload: payload, raw: raw)
        }
        return ClaudeDecodedBlock(summary: summary(for: payload), payload: payload)
    }

    private mutating func decodeToolResult(
        _ object: [String: JSONValue],
        accumulator: inout TranscriptDecodeAccumulator
    ) -> ClaudeDecodedBlock {
        let id = object["tool_use_id"]?.string
        let fragments = textBudget.body(object["content"]?.textFragments().joined(separator: "\n") ?? "")
        let exitCode = exitCode(in: object)
        let duration = durationSeconds(in: object)
        let reportedStatus = object["status"]?.string
            ?? (exitCode.map { $0 == 0 ? "succeeded" : "failed" } ?? "completed")
        guard let id, let pending = pendingTools.removeValue(forKey: id) else {
            accumulator.countUnknown("tool_result")
            let payload = EntryPayload.toolRun(ToolRunPayload(
                toolName: "Unknown tool",
                argumentSummary: "Missing invocation metadata",
                resultSummary: fragments,
                isTerminal: false,
                exitCode: exitCode,
                isRunning: false,
                toolCallID: id,
                output: fragments,
                durationSeconds: duration,
                status: "unpaired_result:\(reportedStatus)"
            ))
            return ClaudeDecodedBlock(summary: summary(for: payload), payload: payload)
        }
        let payload = payloadByAddingResult(
            pending.payload,
            resultSummary: fragments,
            exitCode: exitCode,
            durationSeconds: duration,
            status: reportedStatus
        )
        return ClaudeDecodedBlock(summary: summary(for: payload), payload: payload)
    }

    private func payloadForToolUse(name: String, input: JSONValue?, toolCallID: String?) -> EntryPayload {
        let detail = textBudget.inputDetail(rendered(input))
        return switch name {
        case "Write":
            .fileChange(FileChangePayload(
                path: textBudget.inputDetail(filePath(in: input) ?? ""),
                changeKind: .write,
                toolCallID: toolCallID
            ))
        case "Edit", "MultiEdit":
            .fileChange(FileChangePayload(
                path: textBudget.inputDetail(filePath(in: input) ?? ""),
                changeKind: .edit,
                toolCallID: toolCallID,
                unifiedDiff: editDetail(in: input)
            ))
        case "NotebookEdit":
            .fileChange(FileChangePayload(
                path: textBudget.inputDetail(filePath(in: input) ?? ""),
                changeKind: .notebook,
                toolCallID: toolCallID,
                unifiedDiff: textBudget.body(detail)
            ))
        case "AskUserQuestion":
            .question(QuestionPayload(prompt: questionPrompt(in: input), options: questionOptions(in: input)))
        case "Bash":
            .toolRun(ToolRunPayload(
                toolName: name,
                argumentSummary: textBudget.summaryArgument(commandSummary(in: input)),
                isTerminal: true,
                isRunning: true,
                toolCallID: toolCallID,
                inputDetail: detail,
                command: textBudget.inputDetail(commandSummary(in: input)),
                status: "running"
            ))
        default:
            .toolRun(ToolRunPayload(
                toolName: name,
                argumentSummary: textBudget.summaryArgument(commandSummary(in: input)),
                isTerminal: false,
                isRunning: true,
                toolCallID: toolCallID,
                inputDetail: detail,
                status: "running"
            ))
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

    private func durationSeconds(in object: [String: JSONValue]) -> Double? {
        object["duration_seconds"]?.number
            ?? object["durationSeconds"]?.number
            ?? object["duration_ms"]?.number.map { $0 / 1_000 }
            ?? object["durationMs"]?.number.map { $0 / 1_000 }
    }

    private func rendered(_ value: JSONValue?) -> String {
        guard let value, let data = try? JSONEncoder().encode(value) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    private func editDetail(in input: JSONValue?) -> String? {
        guard let object = input?.object else { return nil }
        if let diff = object["patch"]?.string ?? object["diff"]?.string {
            return textBudget.body(diff)
        }
        let old = object["old_string"]?.string
        let new = object["new_string"]?.string
        guard old != nil || new != nil else { return nil }
        return textBudget.body("--- before\n\(old ?? "")\n+++ after\n\(new ?? "")")
    }

    private func attachmentPayload(in object: [String: JSONValue]) -> AttachmentPayload {
        let kind = object["type"]?.string ?? object["kind"]?.string ?? "file"
        let displayName = object["fileName"]?.string ?? object["file_name"]?.string ?? object["name"]?.string
        let hostPath = object["path"]?.string ?? object["file_path"]?.string
        return AttachmentPayload(
            kind: kind,
            summary: displayName ?? hostPath ?? "\(kind.capitalized) attachment",
            attachmentID: object["id"]?.string,
            displayName: displayName,
            hostPath: hostPath,
            mimeType: object["mediaType"]?.string ?? object["media_type"]?.string ?? object["mime_type"]?.string,
            byteCount: object["size"]?.int ?? object["byte_count"]?.int,
            width: object["width"]?.int,
            height: object["height"]?.int
        )
    }

    private func estimatedDecodedByteCount(_ base64: String) -> Int {
        let padding = base64.suffix(2).filter { $0 == "=" }.count
        return max(0, base64.utf8.count * 3 / 4 - padding)
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
