import Foundation

/// Carries the rich, wire-carriable content for a transcript entry.
public enum EntryPayload: Codable, Hashable, Sendable {
    /// A user-authored message.
    case userMessage(UserMessagePayload)
    /// Agent prose intended for display.
    case agentProse(AgentProsePayload)
    /// Agent thought or reasoning content.
    case thought(ThoughtPayload)
    /// A tool execution entry.
    case toolRun(ToolRunPayload)
    /// A file-change entry.
    case fileChange(FileChangePayload)
    /// A question entry.
    case question(QuestionPayload)
    /// A permission request entry.
    case permission(PermissionPayload)
    /// A status entry.
    case status(StatusPayload)
    /// An attachment entry.
    case attachment(AttachmentPayload)
    /// An unrecognized payload preserved for fail-open decoding.
    case unknown(UnknownPayload)

    private enum CodingKeys: String, CodingKey {
        case kind
        case rawKind = "raw_kind"
        case summary
    }

    /// A deterministic FNV-1a hash over the payload's canonical JSON encoding.
    ///
    /// Producers may use this value as ``EntryContent/contentHash`` when they do
    /// not have a stronger domain-specific hash. Stores still treat the producer
    /// supplied hash as authoritative.
    public var stableHash: Int {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = (try? encoder.encode(self)) ?? Data()
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in data {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return Int(truncatingIfNeeded: hash)
    }

    /// Decodes a fail-open entry payload, preserving non-object values as unknown content.
    /// - Parameter decoder: The decoder to read from.
    public init(from decoder: any Decoder) throws {
        let raw = RawJSONValue.boundedCanonicalString(from: decoder)
        guard let container = try? decoder.container(keyedBy: CodingKeys.self) else {
            self = .unknown(UnknownPayload(
                rawKind: "unknown",
                rawJSON: raw.value,
                rawJSONTruncated: raw.truncated
            ))
            return
        }
        let kind = (try? container.decode(String.self, forKey: .kind)) ?? "unknown"
        let fallbackSummary = try? container.decodeIfPresent(String.self, forKey: .summary)
        self = EntryPayload.decodeKnown(
            kind: kind,
            hasRawKind: container.contains(.rawKind),
            decoder: decoder,
            rawJSON: raw.value,
            rawJSONTruncated: raw.truncated,
            summary: fallbackSummary ?? nil
        )
    }

    /// Encodes a tagged entry payload.
    /// - Parameter encoder: The encoder to write to.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind.rawValue, forKey: .kind)
        switch self {
        case .userMessage(let payload):
            try payload.encode(to: encoder)
        case .agentProse(let payload):
            try payload.encode(to: encoder)
        case .thought(let payload):
            try payload.encode(to: encoder)
        case .toolRun(let payload):
            try payload.encode(to: encoder)
        case .fileChange(let payload):
            try payload.encode(to: encoder)
        case .question(let payload):
            try payload.encode(to: encoder)
        case .permission(let payload):
            try payload.encode(to: encoder)
        case .status(let payload):
            try payload.encode(to: encoder)
        case .attachment(let payload):
            try payload.encode(to: encoder)
        case .unknown(let payload):
            try payload.encode(to: encoder)
        }
    }

    /// The matching entry kind.
    public var kind: EntryKind {
        switch self {
        case .userMessage:
            .userMessage
        case .agentProse:
            .agentProse
        case .thought:
            .thought
        case .toolRun:
            .toolRun
        case .fileChange:
            .fileChange
        case .question:
            .question
        case .permission:
            .permission
        case .status:
            .status
        case .attachment:
            .attachment
        case .unknown(let payload):
            .unknown(payload.rawKind)
        }
    }

    private static func decodeKnown(
        kind: String,
        hasRawKind: Bool,
        decoder: any Decoder,
        rawJSON: String?,
        rawJSONTruncated: Bool,
        summary: String?
    ) -> EntryPayload {
        if hasRawKind, let payload = try? UnknownPayload(from: decoder) {
            return .unknown(payload)
        }
        switch kind {
        case EntryKind.userMessage.rawValue:
            if let payload = try? UserMessagePayload(from: decoder) {
                return .userMessage(payload)
            }
        case EntryKind.agentProse.rawValue:
            if let payload = try? AgentProsePayload(from: decoder) {
                return .agentProse(payload)
            }
        case EntryKind.thought.rawValue:
            if let payload = try? ThoughtPayload(from: decoder) {
                return .thought(payload)
            }
        case EntryKind.toolRun.rawValue:
            if let payload = try? ToolRunPayload(from: decoder) {
                return .toolRun(payload)
            }
        case EntryKind.fileChange.rawValue:
            if let payload = try? FileChangePayload(from: decoder) {
                return .fileChange(payload)
            }
        case EntryKind.question.rawValue:
            if let payload = try? QuestionPayload(from: decoder) {
                return .question(payload)
            }
        case EntryKind.permission.rawValue:
            if let payload = try? PermissionPayload(from: decoder) {
                return .permission(payload)
            }
        case EntryKind.status.rawValue:
            if let payload = try? StatusPayload(from: decoder) {
                return .status(payload)
            }
        case EntryKind.attachment.rawValue:
            if let payload = try? AttachmentPayload(from: decoder) {
                return .attachment(payload)
            }
        default:
            break
        }
        return .unknown(UnknownPayload(rawKind: kind, summary: summary, rawJSON: rawJSON, rawJSONTruncated: rawJSONTruncated))
    }
}
