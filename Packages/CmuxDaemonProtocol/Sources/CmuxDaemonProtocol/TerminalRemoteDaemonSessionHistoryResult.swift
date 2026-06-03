public import Foundation

/// A session's scrollback history returned by ``DaemonRPCMethod/sessionHistory``.
public struct TerminalRemoteDaemonSessionHistoryResult: Decodable, Equatable, Sendable {
    /// The session identifier.
    public let sessionID: String
    /// The rendered history payload, in the requested format.
    public let history: String
    /// The offset to resume reading from, if the daemon reported one.
    public let nextOffset: UInt64?

    /// Creates a session-history result value.
    /// - Parameters:
    ///   - sessionID: The session identifier.
    ///   - history: The rendered history payload.
    ///   - nextOffset: The offset to resume from, if any.
    public init(sessionID: String, history: String, nextOffset: UInt64? = nil) {
        self.sessionID = sessionID
        self.history = history
        self.nextOffset = nextOffset
    }

    /// Decodes a session-history result.
    /// - Parameter decoder: The decoder to read from.
    /// - Throws: A `DecodingError` if a required field is missing.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sessionID = try container.decode(String.self, forKey: .sessionID)
        history = try container.decode(String.self, forKey: .history)
        nextOffset = try container.decodeIfPresent(UInt64.self, forKey: .nextOffset)
    }

    private enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case history
        case nextOffset = "next_offset"
    }
}
