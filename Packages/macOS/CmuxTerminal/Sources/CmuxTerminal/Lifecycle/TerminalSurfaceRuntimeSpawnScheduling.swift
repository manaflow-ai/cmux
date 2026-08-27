public import Foundation

/// Schedules native runtime creation for restored terminal surfaces.
@MainActor
public protocol TerminalSurfaceRuntimeSpawnScheduling: AnyObject {
    /// Enqueues one restored surface's native runtime creation.
    ///
    /// - Parameters:
    ///   - surfaceId: The logical terminal surface identity.
    ///   - operation: The main-actor operation that creates the native runtime surface.
    func scheduleRestoredSurfaceSpawn(
        surfaceId: UUID,
        operation: @escaping @MainActor () -> Void
    )
}
