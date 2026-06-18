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
    /// Registers a live surface and records its focus placement.
    func register(_ surface: any TerminalSurfacing)

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

    /// Whether the surface with the given id is placed in the right-sidebar
    /// dock.
    func isRightSidebarDockSurface(id: UUID) -> Bool

    /// All live registered surfaces, ordered by id for stable iteration.
    func allSurfaces() -> [any TerminalSurfacing]
}
