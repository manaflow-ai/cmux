import Foundation

/// One provider operation that is currently creating a projection for a resource.
@MainActor
struct SurfaceProjectionMaterialization {
    let token: UUID
    let task: Task<Void, Never>
    var waiters: [UUID: (reused: Bool, continuation: CheckedContinuation<Result, Error>)]

    typealias Result = (projection: SurfaceProjection, reused: Bool)
}
