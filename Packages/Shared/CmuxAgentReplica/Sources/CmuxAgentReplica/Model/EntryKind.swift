import Foundation

/// Describes the semantic kind of a transcript entry.
public enum EntryKind: Codable, Hashable, Sendable {
    /// A user-authored message.
    case userMessage
    /// Agent prose intended for display.
    case agentProse
    /// Agent thought or reasoning content.
    case thought
    /// A tool execution entry.
    case toolRun
    /// A file-change entry.
    case fileChange
    /// A question entry.
    case question
    /// A permission request entry.
    case permission
    /// A status entry.
    case status
    /// An attachment entry.
    case attachment
    /// An unrecognized entry kind preserved for fail-open decoding.
    case unknown(String)

    /// The raw string carried in replay logs.
    public var rawValue: String {
        switch self {
        case .userMessage: "userMessage"
        case .agentProse: "agentProse"
        case .thought: "thought"
        case .toolRun: "toolRun"
        case .fileChange: "fileChange"
        case .question: "question"
        case .permission: "permission"
        case .status: "status"
        case .attachment: "attachment"
        case .unknown(let raw): raw
        }
    }

    /// Creates an entry kind from a raw string.
    /// - Parameter rawValue: The raw entry kind.
    public init(rawValue: String) {
        switch rawValue {
        case "userMessage": self = .userMessage
        case "agentProse": self = .agentProse
        case "thought": self = .thought
        case "toolRun": self = .toolRun
        case "fileChange": self = .fileChange
        case "question": self = .question
        case "permission": self = .permission
        case "status": self = .status
        case "attachment": self = .attachment
        default: self = .unknown(rawValue)
        }
    }

    /// Decodes a fail-open entry kind.
    /// - Parameter decoder: The decoder to read from.
    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self.init(rawValue: raw)
    }

    /// Encodes the raw entry kind string.
    /// - Parameter encoder: The encoder to write to.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}
