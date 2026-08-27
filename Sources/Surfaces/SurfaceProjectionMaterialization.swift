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

    typealias Result = (projection: SurfaceProjection, reused: Bool)
}

/// A bounded token record for an operation that can still report after the catalog moved on.
/// The provider is held by the provider task itself and is passed to the late-result callback,
/// so this record never keeps a disconnected provider alive.
@MainActor
struct SurfaceProjectionMaterializationRetirement {
    var evictionTask: Task<Void, Never>?
}
