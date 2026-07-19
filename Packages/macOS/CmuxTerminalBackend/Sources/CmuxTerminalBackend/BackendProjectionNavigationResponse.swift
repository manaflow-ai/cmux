/// The application-level result of a v2 projection-navigation command.
public enum BackendProjectionNavigationResponse: Codable, Equatable, Sendable {
    /// The command applied against the stated topology revision.
    case applied(BackendProjectionNavigationApplied)

    /// The command was rejected without mutating projection state.
    case conflict(BackendProjectionNavigationConflict)

    /// Decodes the response's `status` discriminator and case payload.
    ///
    /// - Parameter decoder: The decoder containing the response object.
    /// - Throws: A decoding error for an unknown status or malformed case payload.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Status.self, forKey: .status) {
        case .applied:
            self = .applied(try BackendProjectionNavigationApplied(from: decoder))
        case .conflict:
            self = .conflict(
                try container.decode(BackendProjectionNavigationConflict.self, forKey: .conflict)
            )
        }
    }

    /// Encodes the response's `status` discriminator and case payload.
    ///
    /// - Parameter encoder: The encoder receiving the response object.
    /// - Throws: Any error raised by the encoder.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .applied(let applied):
            try container.encode(Status.applied, forKey: .status)
            try container.encode(applied.topologyRevision, forKey: .topologyRevision)
            try container.encodeIfPresent(applied.clientRevision, forKey: .clientRevision)
            try container.encodeIfPresent(applied.nextCursor, forKey: .nextCursor)
            try container.encode(applied.states, forKey: .states)
        case .conflict(let conflict):
            try container.encode(Status.conflict, forKey: .status)
            try container.encode(conflict, forKey: .conflict)
        }
    }

    private enum Status: String, Codable {
        case applied
        case conflict
    }

    private enum CodingKeys: String, CodingKey {
        case status
        case conflict
        case topologyRevision = "topology_revision"
        case clientRevision = "client_revision"
        case nextCursor = "next_cursor"
        case states
    }
}
