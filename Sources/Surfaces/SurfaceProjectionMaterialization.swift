import Foundation

/// One provider operation that is currently creating a projection for a resource.
@MainActor
struct SurfaceProjectionMaterialization {
    /// Coalesces one remote view within its destination and pending pane generation.
    struct Key: Hashable {
        let resource: SurfaceResourceID
        let remoteTabID: String?
        let workspaceID: UUID?
        let loadingPanelID: UUID?
        var machine: SurfaceMachineID { resource.machine }
    }

    let token: UUID
    let provider: any SurfaceProvider
    let task: Task<Void, Never>
    var abandonmentDeadlineTask: Task<Void, Never>?
    var abandoned = false
    var waiters: [UUID: (reused: Bool, continuation: CheckedContinuation<Result, Error>)]
    /// Set once the provider task has completed. The operation remains in the catalog until a
    /// resumed caller claims the result, all callers cancel, or bounded retention expires.
    var completedProjection: SurfaceProjection?
    var completionOwnsProjection = false
    var pendingAcknowledgements: Set<UUID> = []
    var completionCleanupTask: Task<Void, Never>?

    typealias Result = (projection: SurfaceProjection, reused: Bool)
}
