public import CmuxAgentReplica
import Foundation

/// Decodes Claude Code project JSONL transcripts into fail-open entries.
///
/// Claude records can contain multiple content blocks on one JSONL line. This
/// decoder emits exactly one ``EntrySnapshot`` per source line; summaries are
/// joined in source order and the dominant kind is chosen by display impact:
/// question, file change, tool run, thought, prose/message, then unknown.
public struct ClaudeTranscriptDecoder: TranscriptDecoder, Sendable {
    private let lineDecoder: JSONLineDecoder
    private var pendingTools: [String: PendingToolUse]

    /// Creates a Claude transcript decoder.
    public init() {
        self.lineDecoder = JSONLineDecoder()
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
            accumulator.emit(kind: .unknown("malformed"), summary: "Malformed transcript line", raw: line, journalID: journalID, lineIndex: lineIndex)
            return
        }
        if root["isSidechain"]?.bool == true || root["isMeta"]?.bool == true {
            accumulator.countUnknown(root["isMeta"]?.bool == true ? "meta" : "sidechain")
            return
        }
        guard let recordType = root["type"]?.string else {
            accumulator.countUnknown("missing_type")
            accumulator.emit(kind: .unknown("missing_type"), summary: "Missing Claude record type", raw: line, journalID: journalID, lineIndex: lineIndex)
            return
        }
        switch recordType {
        case "user", "assistant":
            decodeMessageRecord(root, roleHint: recordType, raw: line, lineIndex: lineIndex, journalID: journalID, accumulator: &accumulator)
        case "attachment", "summary":
            accumulator.countUnknown(recordType)
        default:
            accumulator.countUnknown(recordType)
            accumulator.emit(kind: .unknown(recordType), summary: "Unknown Claude record: \(recordType)", raw: line, journalID: journalID, lineIndex: lineIndex)
        }
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
            accumulator.emit(kind: .unknown("missing_content"), summary: "Missing Claude content", raw: raw, journalID: journalID, lineIndex: lineIndex)
            return
        }
        if let text = content.string {
            let kind: EntryKind = role == "user" ? .userMessage : .agentProse
            accumulator.emit(kind: kind, summary: text, raw: raw, journalID: journalID, lineIndex: lineIndex)
            return
        }
        guard let blocks = content.array else {
            accumulator.countUnknown("content")
            accumulator.emit(kind: .unknown("content"), summary: "Unknown Claude content shape", raw: raw, journalID: journalID, lineIndex: lineIndex)
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
        let kind = dominantKind(in: decodedBlocks)
        let summary = decodedBlocks.map(\.summary).filter { !$0.isEmpty }.joined(separator: "\n")
        accumulator.emit(kind: kind, summary: summary, raw: raw, journalID: journalID, lineIndex: lineIndex)
    }

    private mutating func decodeBlock(
        _ block: JSONValue,
        role: String,
        raw: String,
        accumulator: inout TranscriptDecodeAccumulator
    ) -> ClaudeDecodedBlock? {
        guard let object = block.object, let type = object["type"]?.string else {
            accumulator.countUnknown("block")
            return ClaudeDecodedBlock(kind: .unknown("block"), summary: "Unknown Claude block")
        }
        switch type {
        case "text":
            return ClaudeDecodedBlock(kind: role == "user" ? .userMessage : .agentProse, summary: object["text"]?.string ?? "")
        case "thinking":
            return ClaudeDecodedBlock(kind: .thought, summary: object["thinking"]?.string ?? object["text"]?.string ?? "")
        case "tool_use":
            return decodeToolUse(object, raw: raw)
        case "tool_result":
            return decodeToolResult(object, accumulator: &accumulator)
        default:
            accumulator.countUnknown(type)
            return ClaudeDecodedBlock(kind: .unknown(type), summary: "Unknown Claude block: \(type)")
        }
    }

    private mutating func decodeToolUse(
        _ object: [String: JSONValue],
        raw: String
    ) -> ClaudeDecodedBlock {
        let toolName = object["name"]?.string ?? "unknown"
        let kind = kindForTool(name: toolName)
        let summary = "Tool \(toolName)"
        if let id = object["id"]?.string {
            pendingTools[id] = PendingToolUse(kind: kind, summary: summary, raw: raw)
        }
        return ClaudeDecodedBlock(kind: kind, summary: summary)
    }

    private mutating func decodeToolResult(
        _ object: [String: JSONValue],
        accumulator: inout TranscriptDecodeAccumulator
    ) -> ClaudeDecodedBlock {
        guard let id = object["tool_use_id"]?.string, let pending = pendingTools.removeValue(forKey: id) else {
            accumulator.countUnknown("tool_result")
            return ClaudeDecodedBlock(kind: .unknown("tool_result"), summary: "Unpaired Claude tool result")
        }
        let fragments = object["content"]?.textFragments().joined(separator: "\n") ?? ""
        return ClaudeDecodedBlock(kind: pending.kind, summary: "\(pending.summary) result \(fragments)")
    }

    private func kindForTool(name: String) -> EntryKind {
        switch name {
        case "Write", "Edit", "MultiEdit", "NotebookEdit":
            .fileChange
        case "AskUserQuestion":
            .question
        case "Bash":
            .toolRun
        default:
            .toolRun
        }
    }

    private func dominantKind(in blocks: [ClaudeDecodedBlock]) -> EntryKind {
        blocks.min { lhs, rhs in
            priority(for: lhs.kind) < priority(for: rhs.kind)
        }?.kind ?? .unknown("empty")
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
}
