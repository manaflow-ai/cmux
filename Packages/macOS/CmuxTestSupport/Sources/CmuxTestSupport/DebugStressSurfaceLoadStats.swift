#if DEBUG
public import Foundation

/// The timing and outcome summary of forcing every queued terminal surface in a
/// debug stress batch to load.
///
/// ``DebugStressWorkspaceDriver`` returns this from its surface-readiness pass
/// so the entry point can emit the `stress.setup.done` log line and the
/// `NSLog` summary. It is a pure value with no live references, lifted verbatim
/// from the legacy `AppDelegate.DebugStressSurfaceLoadStats`.
public struct DebugStressSurfaceLoadStats: Sendable, Equatable {
    /// Terminal surfaces still unloaded across the batch after the pass.
    public var pendingSurfaces: Int

    /// Terminal panels whose surface finished loading.
    public var loadedPanels: Int

    /// Terminal panels that timed out without loading.
    public var failedPanels: Int

    /// Number of surface-start requests issued while waiting.
    public var attempts: Int

    /// Wall-clock duration of the load pass, in milliseconds.
    public var elapsedMs: Double

    /// Creates a stats summary.
    public init(
        pendingSurfaces: Int,
        loadedPanels: Int,
        failedPanels: Int,
        attempts: Int,
        elapsedMs: Double
    ) {
        self.pendingSurfaces = pendingSurfaces
        self.loadedPanels = loadedPanels
        self.failedPanels = failedPanels
        self.attempts = attempts
        self.elapsedMs = elapsedMs
    }

    /// The empty summary returned when there are no workspaces to load.
    public static let empty = DebugStressSurfaceLoadStats(
        pendingSurfaces: 0,
        loadedPanels: 0,
        failedPanels: 0,
        attempts: 0,
        elapsedMs: 0
    )
}
#endif
