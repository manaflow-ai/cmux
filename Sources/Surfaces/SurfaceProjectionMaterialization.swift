import Foundation

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
    var completedProjection: SurfaceProjection?
    var completionOwnsProjection = false
    var pendingAcknowledgements: Set<UUID> = []

    typealias Result = (projection: SurfaceProjection, reused: Bool)
}
