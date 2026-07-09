import Foundation

/// Describes the replicated lifecycle of a local send ticket.
public enum SendTicketState: Codable, Hashable, Sendable {
    /// The ticket is queued locally.
    case queuedLocal
    /// The Mac accepted the ticket.
    case acceptedByMac
    /// The Mac injected the ticket into the session.
    case injected
    /// The ticket echoed as a transcript entry.
    case echoed(EntrySeq)
    /// The ticket failed with a stable error code.
    case failed(code: String)
    /// The ticket exists but the Mac has not confirmed its state.
    case unconfirmed

    private enum CodingKeys: String, CodingKey {
        case type
        case seq
        case code
    }

    /// Decodes a send ticket state.
    /// - Parameter decoder: The decoder to read from.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .type) {
        case "queuedLocal": self = .queuedLocal
        case "acceptedByMac": self = .acceptedByMac
        case "injected": self = .injected
        case "echoed": self = .echoed(try container.decode(EntrySeq.self, forKey: .seq))
        case "failed": self = .failed(code: try container.decode(String.self, forKey: .code))
        default: self = .unconfirmed
        }
    }

    /// Encodes a send ticket state.
    /// - Parameter encoder: The encoder to write to.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .queuedLocal:
            try container.encode("queuedLocal", forKey: .type)
        case .acceptedByMac:
            try container.encode("acceptedByMac", forKey: .type)
        case .injected:
            try container.encode("injected", forKey: .type)
        case .echoed(let seq):
            try container.encode("echoed", forKey: .type)
            try container.encode(seq, forKey: .seq)
        case .failed(let code):
            try container.encode("failed", forKey: .type)
            try container.encode(code, forKey: .code)
        case .unconfirmed:
            try container.encode("unconfirmed", forKey: .type)
        }
    }

    var isResolved: Bool {
        switch self {
        case .echoed, .failed:
            true
        case .queuedLocal, .acceptedByMac, .injected, .unconfirmed:
            false
        }
    }
}
