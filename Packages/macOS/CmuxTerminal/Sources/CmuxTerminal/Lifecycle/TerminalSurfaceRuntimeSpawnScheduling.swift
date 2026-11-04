public import Foundation

/// Schedules native runtime creation for restored terminal surfaces.
@MainActor
public protocol TerminalSurfaceRuntimeSpawnScheduling: AnyObject {
    /// Enqueues one restored surface's native runtime creation.
    ///
    /// - Parameters:
    ///   - surfaceId: The logical terminal surface identity.
    ///   - resumesAgent: Whether the spawn runs an admitted agent resume
    ///     command, which costs far more than a login shell.
    ///   - operation: The main-actor operation that creates the native runtime surface.
    func scheduleRestoredSurfaceSpawn(
        surfaceId: UUID,
        resumesAgent: Bool,
        operation: @escaping @MainActor () -> Void
    )
}

extension TerminalSurfaceRuntimeSpawnScheduling {
    /// Enqueues one restored shell surface's native runtime creation.
    public func scheduleRestoredSurfaceSpawn(
        surfaceId: UUID,
        operation: @escaping @MainActor () -> Void
    ) {
        scheduleRestoredSurfaceSpawn(surfaceId: surfaceId, resumesAgent: false, operation: operation)
    }
}
