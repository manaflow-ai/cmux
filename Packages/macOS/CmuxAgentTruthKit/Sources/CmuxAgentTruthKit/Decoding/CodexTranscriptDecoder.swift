public import CmuxAgentReplica
import Foundation

/// Decodes Codex rollout JSONL transcripts into fail-open entries.
public struct CodexTranscriptDecoder: TranscriptDecoder, Sendable {
    private let lineDecoder: JSONLineDecoder
    private var pendingCalls: [String: PendingToolUse]

    /// Creates a Codex transcript decoder.
    public init() {
        self.lineDecoder = JSONLineDecoder()
        self.pendingCalls = [:]
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
            accumulator.emit(kind: .unknown("malformed"), summary: "Malformed transcript line", raw: line, journalID: journalID, lineIndex: lineIndex)
            return
        }
        guard let type = root["type"]?.string else {
            accumulator.countUnknown("missing_type")
            accumulator.emit(kind: .unknown("missing_type"), summary: "Missing Codex record type", raw: line, journalID: journalID, lineIndex: lineIndex)
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
            accumulator.emit(kind: .status, summary: "Conversation compacted", raw: line, journalID: journalID, lineIndex: lineIndex)
        default:
            accumulator.countUnknown(type)
            accumulator.emit(kind: .unknown(type), summary: "Unknown Codex record: \(type)", raw: line, journalID: journalID, lineIndex: lineIndex)
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
        accumulator.emit(kind: .status, summary: "Codex session \(version)", raw: raw, journalID: journalID, lineIndex: lineIndex)
    }

    private mutating func decodeEventMessage(
        _ payload: [String: JSONValue],
        raw: String,
        lineIndex: Int,
        journalID: JournalID,
        accumulator: inout TranscriptDecodeAccumulator
    ) {
        let eventType = payload["type"]?.string ?? "event"
        if eventType == "compacted" || eventType == "compact_complete" {
            accumulator.emit(kind: .status, summary: "Conversation compacted", raw: raw, journalID: journalID, lineIndex: lineIndex)
        } else {
            accumulator.countUnknown("event_msg.\(eventType)")
        }
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
            accumulator.emit(kind: .unknown("missing_response_item_type"), summary: "Missing Codex response item type", raw: raw, journalID: journalID, lineIndex: lineIndex)
            return
        }
        switch itemType {
        case "message":
            decodeMessage(payload, raw: raw, lineIndex: lineIndex, journalID: journalID, accumulator: &accumulator)
        case "reasoning":
            accumulator.emit(kind: .thought, summary: payload["summary"]?.textFragments().joined(separator: "\n") ?? payload["content"]?.textFragments().joined(separator: "\n") ?? "", raw: raw, journalID: journalID, lineIndex: lineIndex)
        case "function_call":
            decodeFunctionCall(payload, raw: raw, lineIndex: lineIndex, journalID: journalID, accumulator: &accumulator)
        case "function_call_output":
            decodeFunctionOutput(payload, raw: raw, lineIndex: lineIndex, journalID: journalID, accumulator: &accumulator)
        case "custom_tool_call", "web_search_call":
            decodeFunctionCall(payload, raw: raw, lineIndex: lineIndex, journalID: journalID, accumulator: &accumulator)
        default:
            accumulator.countUnknown(itemType)
            accumulator.emit(kind: .unknown(itemType), summary: "Unknown Codex response item: \(itemType)", raw: raw, journalID: journalID, lineIndex: lineIndex)
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
        accumulator.emit(kind: role == "user" ? .userMessage : .agentProse, summary: text, raw: raw, journalID: journalID, lineIndex: lineIndex)
    }

    private mutating func decodeFunctionCall(
        _ payload: [String: JSONValue],
        raw: String,
        lineIndex: Int,
        journalID: JournalID,
        accumulator: inout TranscriptDecodeAccumulator
    ) {
        let name = payload["name"]?.string ?? payload["call_id"]?.string ?? payload["type"]?.string ?? "call"
        let summary = "Call \(name) \(summarizeArguments(payload["arguments"] ?? payload["input"]))"
        let kind: EntryKind = name == "apply_patch" ? .fileChange : .toolRun
        if let callID = payload["call_id"]?.string {
            pendingCalls[callID] = PendingToolUse(kind: kind, summary: summary, raw: raw)
        }
        accumulator.emit(kind: kind, summary: summary, raw: raw, journalID: journalID, lineIndex: lineIndex)
    }

    private mutating func decodeFunctionOutput(
        _ payload: [String: JSONValue],
        raw: String,
        lineIndex: Int,
        journalID: JournalID,
        accumulator: inout TranscriptDecodeAccumulator
    ) {
        guard let callID = payload["call_id"]?.string, let pending = pendingCalls.removeValue(forKey: callID) else {
            accumulator.countUnknown("function_call_output")
            accumulator.emit(kind: .unknown("function_call_output"), summary: "Unpaired Codex function output", raw: raw, journalID: journalID, lineIndex: lineIndex)
            return
        }
        let output = payload["output"]?.textFragments().joined(separator: "\n") ?? ""
        accumulator.emit(kind: pending.kind, summary: "\(pending.summary) output \(output)", raw: raw, journalID: journalID, lineIndex: lineIndex)
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
}
