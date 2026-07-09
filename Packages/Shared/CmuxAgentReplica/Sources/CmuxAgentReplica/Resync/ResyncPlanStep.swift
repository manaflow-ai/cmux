import Foundation

/// Describes one ordered resync step.
public enum ResyncPlanStep: Codable, Hashable, Sendable {
    /// Drop replicated state because the Mac epoch changed.
    case dropAll
    /// Keep cached state because the epoch is unchanged.
    case keepState
    /// Pull the session directory.
    case pullSessions
    /// Pull the current tail page for an open session.
    case pullTailPage(AgentSessionID)
    /// Flush queued send tickets after state reconciliation.
    case flushTickets

    private enum CodingKeys: String, CodingKey {
        case type
        case sessionID
    }

    /// Decodes a resync step.
    /// - Parameter decoder: The decoder to read from.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .type) {
        case "dropAll": self = .dropAll
        case "keepState": self = .keepState
        case "pullSessions": self = .pullSessions
        case "pullTailPage": self = .pullTailPage(try container.decode(AgentSessionID.self, forKey: .sessionID))
        case "flushTickets": self = .flushTickets
        default: self = .keepState
        }
    }

    /// Encodes a resync step.
    /// - Parameter encoder: The encoder to write to.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .dropAll:
            try container.encode("dropAll", forKey: .type)
        case .keepState:
            try container.encode("keepState", forKey: .type)
        case .pullSessions:
            try container.encode("pullSessions", forKey: .type)
        case .pullTailPage(let sessionID):
            try container.encode("pullTailPage", forKey: .type)
            try container.encode(sessionID, forKey: .sessionID)
        case .flushTickets:
            try container.encode("flushTickets", forKey: .type)
        }
    }
}
