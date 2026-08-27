import Foundation

/// The provider result has been delivered to one or more callers, but each caller still needs
/// to acknowledge that it accepted the result. Keeping that boundary explicit closes the race
/// where cancellation arrives after the catalog records a pane and before the caller checks it.
@MainActor
struct SurfaceProjectionMaterializationCompletion {
    let projection: SurfaceProjection
    let provider: any SurfaceProvider
    let ownsProjection: Bool
}

/// One provider operation that is currently creating a projection for a resource.
@MainActor
struct SurfaceProjectionMaterialization {
    let token: UUID
    let provider: any SurfaceProvider
    let task: Task<Void, Never>
    var abandonmentDeadlineTask: Task<Void, Never>?
    var abandoned = false
    var waiters: [UUID: (reused: Bool, continuation: CheckedContinuation<Result, Error>)]
    /// Set once the provider task has completed. The operation remains in the catalog until all
    /// resumed callers acknowledge or cancel their result.
    var completion: SurfaceProjectionMaterializationCompletion?
    var pendingAcknowledgements: Set<UUID> = []

    typealias Result = (projection: SurfaceProjection, reused: Bool)
}
