import Foundation

/// Persisted identities of the local owners displaying a resource, captured for one read.
/// Cloud resource identity and runtime projection selectors retain their existing meanings.
struct SurfaceProjectionIdentity: Hashable, Sendable {
    let stableSurfaceID: UUID
    let stableWorkspaceID: UUID

}
