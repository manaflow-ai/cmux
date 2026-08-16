public import Foundation
public import GhosttyKit

/// (B) ExternalHover — one borrow of a native surface pointer, granted by
/// `TerminalSurfaceRuntimeTeardownCoordinator.acquireExternalHoverLease`.
/// Value type carrying a unique `id` so `releaseExternalHoverLease` can be
/// exactly-once: an unknown or already-released `id` must never decrement
/// an outstanding count it doesn't actually own (a naive
/// `count - 1`-style release can't distinguish "my lease" from "someone
/// else's lease for the same lifetime", which risks admitting a deferred
/// free while a genuinely different lease is still outstanding).
///
/// Short-lived by construction: acquire it immediately before one bounded
/// C access (a read, or the setter/clear call) and release it immediately
/// after — never across an `await`/suspension such as a filesystem probe.
/// `@unchecked Sendable` for the same reason as
/// `TerminalSurfaceRuntimeScreenTailRequest`: it transports a borrowed raw
/// pointer whose validity is the coordinator's responsibility to enforce,
/// not the type system's.
public struct ExternalHoverSurfaceLease: @unchecked Sendable {
    // `public` (not just `internal`, despite the struct itself already being
    // `public`): Pass 2's AppKit wiring (a different module, the app
    // target) constructs the real `readPhysicalRows`/`callSetter`/
    // `callClear` closures passed into `ExternalHoverWorkService.init` and
    // must read `surface` (and, for symmetry/diagnostics, `id`/`lifetimeID`)
    // off the lease those closures receive — a struct being `public` does
    // NOT make its stored properties public by default.
    public let id: UUID
    public let lifetimeID: RuntimeSurfaceLifetimeID
    public let surface: ghostty_surface_t
}

/// Retains the actor task that tombstones a lifetime until the teardown
/// coordinator has admitted the matching native free. The registry is
/// synchronous so the invalidation task is registered before a nonisolated
/// surface deinit can enqueue its teardown request.
final class ExternalHoverInvalidationTaskRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var tasks: [RuntimeSurfaceLifetimeID: Task<Void, Never>] = [:]

    func insert(_ task: Task<Void, Never>, for lifetimeID: RuntimeSurfaceLifetimeID) {
        lock.lock()
        tasks[lifetimeID] = task
        lock.unlock()
    }

    func remove(for lifetimeID: RuntimeSurfaceLifetimeID) -> Task<Void, Never>? {
        lock.lock()
        defer { lock.unlock() }
        return tasks.removeValue(forKey: lifetimeID)
    }
}

/// (C) ExternalHover diagnostics — a bare `@unchecked Sendable` transport
/// for one already-known-live surface pointer, crossing into
/// `ExternalHoverWorkService.drainForRenderTrigger`'s actor isolation.
/// Unlike `ExternalHoverSurfaceLease` above, this carries no lease `id` —
/// `drainForRenderTrigger` acquires its OWN just-in-time lease internally
/// (see its doc); this wrapper exists solely so a bare `ghostty_surface_t`
/// (not `Sendable`) can cross the actor boundary as a function parameter
/// without triggering Swift 6's "sending" analysis, which (correctly)
/// rejects passing the SAME raw pointer to a `sending` parameter across
/// more than one call — the render trigger's whole point is to be called
/// repeatedly, once per delivered frame, with the same surface.
public struct ExternalHoverRenderTriggerSurface: @unchecked Sendable {
    public let surface: ghostty_surface_t
    public init(_ surface: ghostty_surface_t) {
        self.surface = surface
    }
}

/// (B) ExternalHover — a teardown request deferred because a hover lease
/// was still outstanding for its lifetime when it arrived. Holds the full
/// execution envelope, not just the request: `executionLane` and
/// `isolatedHibernationReservation` must survive the deferral unchanged,
/// or a hibernation-originated teardown would fall back to the default
/// serialized-close lane and leak its isolated slot reservation forever
/// (review Blocking 3).
struct DeferredRuntimeTeardown {
    let request: TerminalSurfaceRuntimeTeardownRequest
    let executionLane: TerminalSurfaceRuntimeTeardownExecutionLane
    let isolatedHibernationReservation: TerminalSurfaceRuntimeTeardownReservation?
}
