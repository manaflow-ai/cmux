import Foundation

/// Describes the lifecycle of a pending ask.
public enum PendingAskState: Codable, Hashable, Sendable {
    /// The ask is active.
    case active
    /// The ask was answered with the selected choice index.
    case answered(choice: Int)
    /// The ask expired.
    case expired
    /// The ask was superseded by later state.
    case superseded

    private enum CodingKeys: String, CodingKey {
        case type
        case choice
    }

    /// Decodes a pending ask state.
    /// - Parameter decoder: The decoder to read from.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .type) {
        case "active": self = .active
        case "answered": self = .answered(choice: try container.decode(Int.self, forKey: .choice))
        case "expired": self = .expired
        case "superseded": self = .superseded
        default: self = .superseded
        }
    }

    /// Encodes a pending ask state.
    /// - Parameter encoder: The encoder to write to.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .active:
            try container.encode("active", forKey: .type)
        case .answered(let choice):
            try container.encode("answered", forKey: .type)
            try container.encode(choice, forKey: .choice)
        case .expired:
            try container.encode("expired", forKey: .type)
        case .superseded:
            try container.encode("superseded", forKey: .type)
        }
    }
}
