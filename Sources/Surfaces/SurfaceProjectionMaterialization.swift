import Foundation

/// One provider operation that is currently creating a projection for a resource.
struct SurfaceProjectionMaterialization {
    let token: UUID
    let task: Task<SurfaceProjection, Error>
}
