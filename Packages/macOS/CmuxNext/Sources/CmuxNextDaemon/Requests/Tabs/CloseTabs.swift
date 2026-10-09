import Foundation

/// Closes several tabs in one daemon commit (`batch-close-v1`). With
/// `endTerminals`, each terminal whose tabs all close ends in that same
/// commit, unless it is kept; a terminal still shown elsewhere keeps running.
public struct CloseTabsRequest: DaemonRequest {
    public typealias Response = CloseTabsResult
    public static let command = "close-tabs"
    public static let requiredCapability: String? = DaemonCapabilities.shared.batchClose
    public var surfaces: [SurfaceID]
    public var endTerminals: Bool
    public var transaction: ClientTransactionID?
    public var mutation: MutationIdentity?
    /// Why the tabs close (`close-reason-v1`); `.sessionEnd` keeps them out of closed history.
    public var reason: CloseReason?

    public init(surfaces: [SurfaceID], endTerminals: Bool, transaction: ClientTransactionID? = nil,
                mutation: MutationIdentity?, reason: CloseReason? = nil) {
        self.surfaces = surfaces
        self.endTerminals = endTerminals
        self.transaction = transaction
        self.mutation = mutation
        self.reason = reason
    }

    enum CodingKeys: String, CodingKey { case surfaces, endTerminals, transaction, reason }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(surfaces, forKey: .surfaces)
        if endTerminals { try c.encode(true, forKey: .endTerminals) }
        try c.encodeIfPresent(transaction, forKey: .transaction)
        try c.encodeIfPresent(reason?.rawValue, forKey: .reason)
        try MutationFields(identity: mutation).encode(to: encoder)
    }
}

/// `close-tabs` result: the closed placements and the terminals that ended.
public struct CloseTabsResult: Decodable, Sendable, Equatable {
    public struct EndedTerminal: Decodable, Sendable, Equatable {
        public var terminalID: TerminalID
        public var terminalIncarnation: TerminalIncarnation?

        enum CodingKeys: String, CodingKey {
            case terminalID = "terminal_id"
            case terminalIncarnation = "terminal_incarnation"
        }
    }

    public var closed: [SurfaceID]
    public var terminals: [EndedTerminal]
    public var resourceRevision: UInt64?
    public var replayed: Bool?

    enum CodingKeys: String, CodingKey {
        case closed, terminals, replayed
        case resourceRevision = "resource_revision"
    }
}

/// Why `close-tabs` closes its tabs (`close-reason-v1`).
public enum CloseReason: String, Sendable, Hashable {
    /// A browser agent session ended and closes the tabs it created and did not keep: like a
    /// close, but not offered by Reopen Closed.
    case sessionEnd = "session_end"
}
