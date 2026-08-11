import CmuxAgentTruthKit
import Foundation

struct TranscriptDecoderGapMapper {
    static func map(source: TranscriptHarvestSource, rawKind: String, rawLine: String) -> [TranscriptDecoderGapKey] {
        switch source {
        case .claude:
            return mapClaude(rawKind, rawLine: rawLine)
        case .codex:
            return mapCodex(rawKind, rawLine: rawLine)
        }
    }

    private static func mapClaude(_ rawKind: String, rawLine: String) -> [TranscriptDecoderGapKey] {
        switch rawKind {
        case "sidechain":
            [TranscriptDecoderGapKey(source: .claude, dimension: "flag", value: "isSidechain")]
        case "meta":
            [TranscriptDecoderGapKey(source: .claude, dimension: "flag", value: "isMeta")]
        case "malformed", "missing_type":
            [TranscriptDecoderGapKey(source: .claude, dimension: "record_type", value: rawKind)]
        case "block", "content", "missing_content", "tool_result":
            [TranscriptDecoderGapKey(source: .claude, dimension: "block_type", value: rawKind)]
        default:
            mapClaudeUnknownKind(rawKind, rawLine: rawLine)
        }
    }

    private static func mapClaudeUnknownKind(_ rawKind: String, rawLine: String) -> [TranscriptDecoderGapKey] {
        guard let root = JSONLineDecoder().decode(rawLine)?.object else {
            return [
                TranscriptDecoderGapKey(source: .claude, dimension: "record_type", value: rawKind),
                TranscriptDecoderGapKey(source: .claude, dimension: "block_type", value: rawKind),
            ]
        }
        if root["type"]?.string == rawKind {
            return [TranscriptDecoderGapKey(source: .claude, dimension: "record_type", value: rawKind)]
        }
        if claudeBlockTypes(in: root).contains(rawKind) {
            return [TranscriptDecoderGapKey(source: .claude, dimension: "block_type", value: rawKind)]
        }
        return [
            TranscriptDecoderGapKey(source: .claude, dimension: "record_type", value: rawKind),
            TranscriptDecoderGapKey(source: .claude, dimension: "block_type", value: rawKind),
        ]
    }

    private static func claudeBlockTypes(in root: [String: JSONValue]) -> Set<String> {
        let message = root["message"]?.object
        let content = message?["content"] ?? root["content"]
        guard let blocks = content?.array else {
            return []
        }
        return Set(blocks.compactMap { $0.object?["type"]?.string })
    }

    private static func mapCodex(_ rawKind: String, rawLine: String) -> [TranscriptDecoderGapKey] {
        if rawKind.hasPrefix("event_msg.") {
            let value = String(rawKind.dropFirst("event_msg.".count))
            return [TranscriptDecoderGapKey(source: .codex, dimension: "event_msg_type", value: value)]
        }
        switch rawKind {
        case "malformed", "missing_type":
            return [TranscriptDecoderGapKey(source: .codex, dimension: "record_type", value: rawKind)]
        case "missing_response_item_type", "function_call_output":
            return [TranscriptDecoderGapKey(source: .codex, dimension: "payload_type", value: rawKind)]
        default:
            return mapCodexUnknownKind(rawKind, rawLine: rawLine)
        }
    }

    private static func mapCodexUnknownKind(_ rawKind: String, rawLine: String) -> [TranscriptDecoderGapKey] {
        guard let root = JSONLineDecoder().decode(rawLine)?.object else {
            return [
                TranscriptDecoderGapKey(source: .codex, dimension: "record_type", value: rawKind),
                TranscriptDecoderGapKey(source: .codex, dimension: "payload_type", value: rawKind),
            ]
        }
        if root["type"]?.string == rawKind {
            return [TranscriptDecoderGapKey(source: .codex, dimension: "record_type", value: rawKind)]
        }
        let payload = root["payload"]?.object ?? root
        if payload["type"]?.string == rawKind {
            return [TranscriptDecoderGapKey(source: .codex, dimension: "payload_type", value: rawKind)]
        }
        return [
            TranscriptDecoderGapKey(source: .codex, dimension: "record_type", value: rawKind),
            TranscriptDecoderGapKey(source: .codex, dimension: "payload_type", value: rawKind),
        ]
    }
}
