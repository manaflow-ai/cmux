import Foundation

/// (C) ExternalHover diagnostics — review round2 B5: the REAL numeric
/// `externalHoverSurfaceSerial` (an app-target/`GhosttyNSView`-owned
/// counter) has no natural home inside
/// `TerminalSurfaceRuntimeTeardownCoordinator` — that coordinator has no
/// `GhosttyNSView` in scope to read it from (see
/// `defaultDrainExternalHoverDiagnostics`'s own prior doc, which is why
/// its final drain used to fall back to `surfaceSerial=0` plus a separate
/// `teardownSurfaceToken=<UUID>` field). `ExternalHoverWorkService` DOES
/// receive the real value on every request
/// (`ExternalHoverWorkRequest.surfaceSerial`), so this registry lets the
/// actor record it once per lifetime; the teardown coordinator's
/// `nonisolated` final drain then looks it up by `lifetimeID` and logs
/// the SAME numeric `surfaceSerial` the normal read/resolve/setter lines
/// already use — closing the `(surfaceSerial, event)` correlation key
/// design v4 requires, instead of the two-scheme `surfaceSerial=0` +
/// `teardownSurfaceToken` split the review rejected outright.
///
/// Shared between the two types exactly like `ExternalHoverDroppedCountTracker`
/// (constructed by `TerminalSurfaceRuntimeTeardownCoordinator`, read off
/// that dependency by `ExternalHoverWorkService` at `init`) — plain
/// lock-protected state, not actor-isolated, since the teardown drain
/// runs `nonisolated` with no actor to hop through to reach the service.
public final class ExternalHoverSurfaceSerialRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var serialsByLifetime: [RuntimeSurfaceLifetimeID: UInt64] = [:]

    public init() {}

    /// Records `serial` as `lifetimeID`'s surface serial. Called
    /// unconditionally on every request the actor processes (regardless
    /// of the diagnostics gate — the LOOKUP is what the gate guards, not
    /// this cheap dictionary write), so by the time any lifetime could
    /// possibly have a ring entry worth correlating, its serial is
    /// already registered.
    public func register(_ serial: UInt64, for lifetimeID: RuntimeSurfaceLifetimeID) {
        lock.lock()
        defer { lock.unlock() }
        serialsByLifetime[lifetimeID] = serial
    }

    /// `nil` if this lifetime was never registered (e.g. a withdrawal for
    /// a lifetime that never actually submitted a request) — callers fall
    /// back to `0`, matching every other diagnostics field's "absent ⇒
    /// zero" convention.
    public func serial(for lifetimeID: RuntimeSurfaceLifetimeID) -> UInt64? {
        lock.lock()
        defer { lock.unlock() }
        return serialsByLifetime[lifetimeID]
    }

    /// Removes a closed lifetime's entry so this dictionary doesn't grow
    /// across surface churn for the lifetime of the process. Safe to call
    /// even if the lifetime was never registered (a no-op).
    public func closeLifetime(_ lifetimeID: RuntimeSurfaceLifetimeID) {
        lock.lock()
        defer { lock.unlock() }
        serialsByLifetime.removeValue(forKey: lifetimeID)
    }
}
