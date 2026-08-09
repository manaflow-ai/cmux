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
