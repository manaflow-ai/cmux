public import Foundation

public struct OwnedAttentionTarget: Hashable, Sendable {
    public let workspaceID: UUID
    public let surfaceID: UUID

    public init(workspaceID: UUID, surfaceID: UUID) {
        self.workspaceID = workspaceID
        self.surfaceID = surfaceID
    }
}

public struct OwnedAttentionSlot: Hashable, Sendable {
    public let producerID: UUID
    public let target: OwnedAttentionTarget

    public init(producerID: UUID, target: OwnedAttentionTarget) {
        self.producerID = producerID
        self.target = target
    }
}

public enum OwnedAttentionProjectionStatus: Equatable, Sendable {
    case visible, deferredForeignUnread, targetUnavailable, muted
}

public enum OwnedAttentionProjectionError: Error, Equatable, Sendable {
    case missingIdentity, identityCollision, staleSnapshot
}

/// A plan must be calculated and applied on the same UI actor without suspension.
public struct OwnedAttentionProjection: Sendable {
    public let rows: [OwnedAttentionSlot: OwnedAttentionDestination]
    public let statuses: [OwnedAttentionSlot: OwnedAttentionProjectionStatus]

    /// Validate against all existing non-owned row IDs before any UI mutation.
    public func validateIdentities(_ identities: [OwnedAttentionSlot: UUID], foreignIDs: Set<UUID>) throws {
        var used = foreignIDs
        for slot in rows.keys {
            guard let identity = identities[slot] else { throw OwnedAttentionProjectionError.missingIdentity }
            guard used.insert(identity).inserted else { throw OwnedAttentionProjectionError.identityCollision }
        }
    }

    public static func plan(
        states: [UUID: OwnedAttentionState],
        unavailable: Set<OwnedAttentionTarget>,
        muted: Set<OwnedAttentionTarget>,
        foreignUnread: Set<OwnedAttentionTarget>
    ) -> Self {
        var rows: [OwnedAttentionSlot: OwnedAttentionDestination] = [:]
        var statuses: [OwnedAttentionSlot: OwnedAttentionProjectionStatus] = [:]
        var occupied = foreignUnread
        for producer in states.keys.sorted(by: { $0.uuidString < $1.uuidString }) {
            guard let state = states[producer] else { continue }
            for destination in state.destinations {
                let target = OwnedAttentionTarget(workspaceID: destination.workspaceID, surfaceID: destination.surfaceID)
                let slot = OwnedAttentionSlot(producerID: producer, target: target)
                if unavailable.contains(target) {
                    statuses[slot] = .targetUnavailable
                } else if muted.contains(target) {
                    statuses[slot] = .muted
                } else if occupied.contains(target) {
                    statuses[slot] = .deferredForeignUnread
                } else {
                    statuses[slot] = .visible
                    rows[slot] = destination
                    occupied.insert(target)
                }
            }
        }
        return Self(rows: rows, statuses: statuses)
    }
}
