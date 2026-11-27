import Foundation

/// A tapback or an emoji reaction.
public enum ConversationReactionKind: Codable, Sendable, Hashable {
    case tapback(String)
    case emoji(String)

    enum CodingKeys: String, CodingKey { case tapback, emoji }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let tapback = try container.decodeIfPresent(String.self, forKey: .tapback) {
            self = .tapback(tapback)
        } else {
            self = .emoji(try container.decode(String.self, forKey: .emoji))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .tapback(let value): try container.encode(value, forKey: .tapback)
        case .emoji(let value): try container.encode(value, forKey: .emoji)
        }
    }
}
