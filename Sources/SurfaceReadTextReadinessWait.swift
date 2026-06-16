import Foundation

nonisolated struct SurfaceReadTextReadinessWait: Sendable {
    let surfaceID: UUID
    let waiterID: UUID
}
