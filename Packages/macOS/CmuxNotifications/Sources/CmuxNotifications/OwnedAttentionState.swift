public import Foundation

/// One producer-owned, silent attention projection for a terminal surface.
public struct OwnedAttentionDestination: Equatable, Sendable, Codable {
    public let workspaceID: UUID
    public let surfaceID: UUID
    public let title: String
    public let body: String

    private enum CodingKeys: String, CodingKey {
        case workspaceID = "workspace_id"
        case surfaceID = "surface_id"
        case title, body
    }

    public init(workspaceID: UUID, surfaceID: UUID, title: String, body: String) {
        self.workspaceID = workspaceID
        self.surfaceID = surfaceID
        self.title = title
        self.body = body
    }
}

/// A rejected state transition must leave the committed register unchanged.
public enum OwnedAttentionStateError: Error, Equatable, Sendable {
    case wrongEpoch
    case staleRevision
    case conflictingRevision
    case duplicateDestination
    case payloadTooLarge
}

/// A value-level transition rule; persistence and writer authorization are separate.
public struct OwnedAttentionState: Equatable, Sendable, Codable {
    public let epoch: UUID
    public let revision: UInt64
    public let destinations: [OwnedAttentionDestination]

    public init(epoch: UUID, revision: UInt64, destinations: [OwnedAttentionDestination]) throws {
        try Self.validate(destinations)
        self.epoch = epoch
        self.revision = revision
        self.destinations = Self.canonical(destinations)
    }

    private enum CodingKeys: String, CodingKey {
        case epoch, revision, destinations
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            epoch: values.decode(UUID.self, forKey: .epoch),
            revision: values.decode(UInt64.self, forKey: .revision),
            destinations: values.decode([OwnedAttentionDestination].self, forKey: .destinations)
        )
    }

    private static func validate(_ destinations: [OwnedAttentionDestination]) throws {
        guard destinations.count <= 256,
              destinations.allSatisfy({ $0.title.utf8.count <= 1024 && $0.body.utf8.count <= 8192 }) else {
            throw OwnedAttentionStateError.payloadTooLarge
        }
        let identities = destinations.map { "\($0.workspaceID.uuidString):\($0.surfaceID.uuidString)" }
        guard Set(identities).count == identities.count else {
            throw OwnedAttentionStateError.duplicateDestination
        }
    }

    private static func canonical(_ destinations: [OwnedAttentionDestination]) -> [OwnedAttentionDestination] {
        destinations.sorted {
            let lhs = ($0.workspaceID.uuidString, $0.surfaceID.uuidString)
            let rhs = ($1.workspaceID.uuidString, $1.surfaceID.uuidString)
            return lhs < rhs
        }
    }

    public func applying(
        epoch: UUID,
        revision: UInt64,
        destinations: [OwnedAttentionDestination]
    ) throws -> OwnedAttentionState {
        guard epoch == self.epoch else { throw OwnedAttentionStateError.wrongEpoch }
        guard revision >= self.revision else { throw OwnedAttentionStateError.staleRevision }
        try Self.validate(destinations)
        if revision == self.revision {
            guard Self.canonical(destinations) == self.destinations else {
                throw OwnedAttentionStateError.conflictingRevision
            }
            return self
        }
        return try OwnedAttentionState(epoch: epoch, revision: revision, destinations: destinations)
    }
}
