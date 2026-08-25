public import Foundation
public import GhosttyKit

/// The process-wide registry of live terminal surfaces and the runtime
/// surface pointers they own.
///
/// The registry answers two questions the rest of the app keeps asking:
/// "which surface model has this id right now" (stale-callback filtering,
/// recoverable-window-route bookkeeping) and "does this runtime pointer still
/// belong to its owner" (use-after-free guards on `ghostty_surface_t`).
///
/// Isolation: requirements are synchronous and `Sendable` on purpose. The
/// surface model unregisters itself from `deinit`, which is nonisolated and
/// cannot await, and runtime-pointer guards run synchronously on the paths
/// that touch the native surface. Implementations guard their tables with a
/// lock instead of actor isolation for exactly that reason.
public protocol TerminalSurfaceRegistering: AnyObject, Sendable {
    /// Monotonically increasing revision of the registered surface topology.
    ///
    /// Consumers that cache per-surface state can compare this value before
    /// enumerating ``allSurfaces()`` instead of rescanning on every terminal
    /// output event.
    var topologyGeneration: UInt64 { get }

    /// Registers a live surface, its process generation, and its focus placement.
    /// - Parameters:
    ///   - surface: The surface model being registered.
    ///   - terminalLifecycleID: The generation exported to its current child.
    func register(
        _ surface: any TerminalSurfacing,
        terminalLifecycleID: UUID
    )

    /// Ends the surface's current process generation and returns the identity
    /// to export to its next child runtime.
    ///
    /// Implementations update their validation state synchronously so delayed
    /// telemetry from the retired child is rejected before this method returns.
    /// - Parameter surface: The retained surface whose child is being replaced.
    /// - Returns: The generation identity for the surface's next child runtime.
    func advanceTerminalLifecycle(
        for surface: any TerminalSurfacing
    ) -> UUID

    /// Removes a surface; drops its focus placement when no other surface
    /// shares the same id.
    func unregister(_ surface: any TerminalSurfacing)

    /// Records `ownerId` as the owner of a live runtime surface pointer.
    func registerRuntimeSurface(_ surface: ghostty_surface_t, ownerId: UUID)

    /// Clears the owner record, but only while `ownerId` still owns it.
    func unregisterRuntimeSurface(_ surface: ghostty_surface_t, ownerId: UUID)

    /// The recorded owner of a runtime surface pointer, if any.
    func runtimeSurfaceOwnerId(_ surface: ghostty_surface_t) -> UUID?

    /// The registered surface with the given id, if it is still alive.
    func surface(id: UUID) -> (any TerminalSurfacing)?

    /// The current terminal process generation for a live surface identity.
    ///
    /// This lookup is atomic with registry lifecycle advancement so callers
    /// can bind tokenless compatibility work to one concrete generation, then
    /// revalidate it before admitting deferred work.
    /// - Parameter surfaceID: The stable terminal surface identity.
    /// - Returns: The current process-generation identity, or `nil` when no
    ///   live surface owns `surfaceID`.
    func terminalLifecycleID(surfaceID: UUID) -> UUID?

    /// The current registered surface that owns a terminal-process generation.
    ///
    /// A token belonging to a superseded registration does not resolve until
    /// that registration becomes the current owner of its stable surface id
    /// again.
    func surface(
        terminalLifecycleID: UUID
    ) -> (any TerminalSurfacing)?

    /// Atomically returns the current surface only when both identities match.
    ///
    /// Validation and retrieval happen inside one synchronization boundary so
    /// callers cannot admit a retired process generation and then retrieve its
    /// replacement.
    func surface(
        id: UUID,
        terminalLifecycleID: UUID
    ) -> (any TerminalSurfacing)?

    /// Whether the current surface owns a reported terminal-process generation.
    ///
    /// A `nil` generation retains compatibility with callers that can only
    /// prove the surface is live. Implementations must compare non-`nil`
    /// generations against the same state updated by
    /// ``advanceTerminalLifecycle(for:)``.
    /// - Parameters:
    ///   - id: The stable surface identity.
    ///   - terminalLifecycleID: The reported process generation, if supplied.
    /// - Returns: Whether the report targets the current registered surface.
    func isCurrentSurface(
        id: UUID,
        terminalLifecycleID: UUID?
    ) -> Bool

    /// Whether the surface with the given id is placed in the right-sidebar
    /// dock.
    func isRightSidebarDockSurface(id: UUID) -> Bool

    /// Re-records the focus placement for a live surface that moved between the
    /// workspace area and the right-sidebar dock. No-op when that surface
    /// registration is no longer present.
    ///
    /// - Parameters:
    ///   - surface: The exact registered model whose placement changed.
    ///   - placement: The surface's new focus-routing placement.
    func updateFocusPlacement(
        for surface: any TerminalSurfacing,
        _ placement: TerminalSurfaceFocusPlacement
    )

    /// Re-records the canonical registration's placement for callers that
    /// only have a stable surface id.
    ///
    /// This compatibility requirement preserves the pre-lifecycle protocol
    /// surface. New code should prefer the exact-registration overload above
    /// so an outgoing duplicate-id model cannot update its replacement.
    func updateFocusPlacement(
        id: UUID,
        _ placement: TerminalSurfaceFocusPlacement
    )

    /// All live registered surfaces, ordered by id for stable iteration.
    func allSurfaces() -> [any TerminalSurfacing]
}

/// Compatibility defaults for the surface registry placement API.
public extension TerminalSurfaceRegistering {
    /// Bridges the exact-registration update to the legacy id-only method so
    /// existing conformers remain source-compatible during the migration.
    func updateFocusPlacement(
        for surface: any TerminalSurfacing,
        _ placement: TerminalSurfaceFocusPlacement
    ) {
        updateFocusPlacement(id: surface.id, placement)
    }
}
