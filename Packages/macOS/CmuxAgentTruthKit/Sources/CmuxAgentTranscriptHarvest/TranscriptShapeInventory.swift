import CmuxAgentTruthKit
import Foundation

struct TranscriptShapeInventory {
    private let lineDecoder: JSONLineDecoder
    private var counts: [TranscriptShapeKey: Int]

    init() {
        self.lineDecoder = JSONLineDecoder()
        self.counts = [:]
    }

    mutating func feed(source: TranscriptHarvestSource, rawLine: String) {
        guard let root = lineDecoder.decode(rawLine)?.object else {
            increment(source: source, dimension: "record_type", value: "malformed")
            return
        }
        switch source {
        case .claude:
            feedClaude(root)
        case .codex:
            feedCodex(root)
        }
    }

    func rows(gaps: TranscriptDecoderGapInventory = TranscriptDecoderGapInventory()) -> [TranscriptShapeRow] {
        counts.map { key, count in
            TranscriptShapeRow(
                source: key.source,
                dimension: key.dimension,
                value: key.value,
                count: count,
                marker: gaps.contains(source: key.source, dimension: key.dimension, value: key.value) ? "DECODER-GAP" : nil
            )
        }
        .sorted { lhs, rhs in
            if lhs.source.rawValue != rhs.source.rawValue {
                return lhs.source.rawValue < rhs.source.rawValue
            }
            if lhs.dimension != rhs.dimension {
                return lhs.dimension < rhs.dimension
            }
            return lhs.value < rhs.value
        }
    }

    private mutating func feedClaude(_ root: [String: JSONValue]) {
        if let recordType = root["type"]?.string {
            increment(source: .claude, dimension: "record_type", value: recordType)
        } else {
            increment(source: .claude, dimension: "record_type", value: "missing_type")
        }
        if root["isSidechain"]?.bool == true {
            increment(source: .claude, dimension: "flag", value: "isSidechain")
        }
        if root["isMeta"]?.bool == true {
            increment(source: .claude, dimension: "flag", value: "isMeta")
        }
        for key in root.keys where !TranscriptKnownKeys.claudeTopLevel.contains(key) {
            increment(source: .claude, dimension: "unfamiliar_top_level_key", value: key)
        }
        let message = root["message"]?.object
        let content = message?["content"] ?? root["content"]
        guard let blocks = content?.array else {
            return
        }
        for block in blocks {
            guard let object = block.object else {
                increment(source: .claude, dimension: "block_type", value: "non_object")
                continue
            }
            let blockType = object["type"]?.string ?? "missing_type"
            increment(source: .claude, dimension: "block_type", value: blockType)
            if blockType == "tool_use", let toolName = object["name"]?.string {
                increment(source: .claude, dimension: "tool_name", value: toolName)
            }
        }
    }

    private mutating func feedCodex(_ root: [String: JSONValue]) {
        let recordType = root["type"]?.string ?? "missing_type"
        increment(source: .codex, dimension: "record_type", value: recordType)
        let payload = root["payload"]?.object ?? root
        switch recordType {
        case "session_meta":
            if let version = payload["cli_version"]?.string {
                increment(source: .codex, dimension: "cli_version", value: version)
            }
        case "response_item":
            let payloadType = payload["type"]?.string ?? "missing_type"
            increment(source: .codex, dimension: "payload_type", value: payloadType)
            if TranscriptKnownKeys.codexFunctionPayloadTypes.contains(payloadType), let name = payload["name"]?.string {
                increment(source: .codex, dimension: "function_call_name", value: name)
            }
        case "event_msg":
            increment(source: .codex, dimension: "event_msg_type", value: payload["type"]?.string ?? "missing_type")
        default:
            return
        }
    }

    private mutating func increment(source: TranscriptHarvestSource, dimension: String, value: String) {
        let key = TranscriptShapeKey(source: source, dimension: dimension, value: TranscriptPrivacySanitizer.identifier(value))
        counts[key, default: 0] += 1
    }
}
