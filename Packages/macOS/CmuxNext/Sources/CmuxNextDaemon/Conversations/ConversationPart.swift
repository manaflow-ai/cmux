import Foundation

/// A styled range of a text part. Offsets are UTF-16 code units.
public struct ConversationTextRun: Codable, Sendable, Hashable {
    public var start: Int
    public var length: Int
    /// The participant this range mentions (`@mux`).
    public var mention: String?
    public var link: String?

    public init(start: Int, length: Int, mention: String? = nil, link: String? = nil) {
        self.start = start
        self.length = length
        self.mention = mention
        self.link = link
    }
}

/// One part of a message. Unknown part types from a newer owner decode as
/// `.unknown` and render as a fallback row instead of failing the message.
public enum ConversationPart: Codable, Sendable, Hashable {
    case text(String, runs: [ConversationTextRun])
    /// A reference to an agent session (acpmux): its status and a reply preview.
    case work(session: String, host: String?, status: String, preview: String?)
    /// A file stored by SHA-256 (`local-attachments-v1`).
    case attachment(ConversationAttachment)
    case unknown(type: String, payload: JSONValue)

    enum CodingKeys: String, CodingKey {
        case type, text, runs, session, host, status, preview
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "text":
            self = .text(try container.decode(String.self, forKey: .text),
                         runs: try container.decodeIfPresent([ConversationTextRun].self, forKey: .runs) ?? [])
        case "work":
            self = .work(session: try container.decode(String.self, forKey: .session),
                         host: try container.decodeIfPresent(String.self, forKey: .host),
                         status: try container.decode(String.self, forKey: .status),
                         preview: try container.decodeIfPresent(String.self, forKey: .preview))
        case "attachment":
            self = .attachment(try ConversationAttachment(from: decoder))
        default:
            self = .unknown(type: type, payload: try JSONValue(from: decoder))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        switch self {
        case .text(let text, let runs):
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode("text", forKey: .type)
            try container.encode(text, forKey: .text)
            if !runs.isEmpty { try container.encode(runs, forKey: .runs) }
        case .work(let session, let host, let status, let preview):
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode("work", forKey: .type)
            try container.encode(session, forKey: .session)
            try container.encodeIfPresent(host, forKey: .host)
            try container.encode(status, forKey: .status)
            try container.encodeIfPresent(preview, forKey: .preview)
        case .attachment(let attachment):
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode("attachment", forKey: .type)
            try attachment.encode(to: encoder)
        case .unknown(_, let payload):
            try payload.encode(to: encoder)
        }
    }

    /// Plain text for previews and fallbacks.
    public var plainText: String {
        switch self {
        case .text(let text, _): text
        case .work(let session, _, let status, let preview): preview ?? "\(session) \(status)"
        case .attachment(let attachment): attachment.name
        case .unknown(let type, _): type
        }
    }
}
