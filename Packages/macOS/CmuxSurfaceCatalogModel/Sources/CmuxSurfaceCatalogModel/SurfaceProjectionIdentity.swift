import Foundation

/// Stable local owner identities captured for one catalog projection read.
///
/// ``SurfaceProjectionIdentity`` joins a catalog projection to the durable surface and
/// workspace identifiers that own it. Runtime panel and workspace selectors remain in
/// ``SurfaceProjection``; this value is only the stable ownership metadata used by
/// socket snapshots and policy decisions.
public struct SurfaceProjectionIdentity: Hashable, Sendable {
    /// The durable surface identifier of the local panel owner.
    public let stableSurfaceID: UUID
    /// The durable workspace identifier of the local workspace owner.
    public let stableWorkspaceID: UUID

    /// Creates an identity from the durable local owner identifiers.
    /// - Parameters:
    ///   - stableSurfaceID: The panel's stable surface identifier.
    ///   - stableWorkspaceID: The workspace's stable identifier.
    public init(stableSurfaceID: UUID, stableWorkspaceID: UUID) {
        self.stableSurfaceID = stableSurfaceID
        self.stableWorkspaceID = stableWorkspaceID
    }
}
