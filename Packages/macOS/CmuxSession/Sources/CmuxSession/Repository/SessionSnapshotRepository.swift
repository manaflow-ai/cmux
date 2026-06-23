public import CmuxWorkspaces
public import Foundation

/// Actor that serializes session-snapshot + primary-window-geometry writes.
///
/// Replaces the legacy `AppDelegate.sessionPersistenceQueue`
/// (`DispatchQueue(label: "com.cmuxterm.app.sessionPersistence", qos:
/// .utility)`): instead of a hand-rolled serial queue captured inside the god
/// file, the queued (asynchronous) writes are serialized by actor isolation.
/// The repository owns one ``CmuxWorkspaces/SessionSnapshotPersistor`` value
/// (which still owns the snapshot store, the geometry store, the geometry
/// defaults, and the wire format) and drives its `persist` method.
///
/// **Isolation design.** Session persistence has exactly two write contexts:
/// the periodic autosave / resign-active save (background-priority, must not
/// block the main actor) and the termination / explicit save (must complete
/// before the process exits). The periodic writes are *queued* — order matters
/// (a later snapshot must not be overwritten by an earlier in-flight write) but
/// they need not block the caller, which is precisely an actor's serial
/// executor. The termination write is *synchronous* — it must land inline on
/// the caller's thread before `applicationWillTerminate` returns, so it cannot
/// be an `await` hop (the run loop is tearing down). The two paths therefore
/// split: ``persistQueued(_:removeWhenEmpty:persistedGeometryData:)`` is an
/// actor method (serialized, awaited fire-and-forget by the main-actor caller),
/// and ``persistSynchronously(_:removeWhenEmpty:persistedGeometryData:)`` is
/// `nonisolated` and runs the persistor inline. Both call the same `Sendable`
/// persistor, so the wire behavior is identical to the legacy
/// `synchronously ? writeBlock() : queue.async(writeBlock)` branch; only the
/// queued lane's mechanism changed from a `DispatchQueue` to actor isolation.
public actor SessionSnapshotRepository<
    SnapshotValue: SessionSnapshotRepresenting,
    GeometryPayload: WindowGeometryPersisting
> {
    private let persistor: SessionSnapshotPersistor<SnapshotValue, GeometryPayload>

    /// Creates a repository over the given persistor.
    ///
    /// - Parameter persistor: the `Sendable` snapshot+geometry write
    ///   coordinator; the composition root constructs it with the app-owned
    ///   snapshot store and geometry store so the wire format stays
    ///   single-sourced.
    public init(persistor: SessionSnapshotPersistor<SnapshotValue, GeometryPayload>) {
        self.persistor = persistor
    }

    /// Serializes one queued (asynchronous) write. Replaces the legacy
    /// `queue.async(execute: writeBlock)` lane. Callers `await` it as
    /// fire-and-forget (`Task { await repository.persistQueued(...) }`), and the
    /// actor's serial executor preserves the write order the serial queue gave.
    public func persistQueued(
        _ snapshot: SnapshotValue?,
        removeWhenEmpty: Bool,
        persistedGeometryData: Data?
    ) {
        persistor.persist(
            snapshot,
            removeWhenEmpty: removeWhenEmpty,
            persistedGeometryData: persistedGeometryData,
            synchronously: true
        )
    }

    /// Runs one synchronous (inline) write on the caller's thread. Replaces the
    /// legacy `synchronously` branch (`writeBlock()`), used by the termination /
    /// explicit scrollback save that must complete before the process exits.
    /// `nonisolated` because it does no actor-state access; it forwards to the
    /// `Sendable` persistor's inline path.
    public nonisolated func persistSynchronously(
        _ snapshot: SnapshotValue?,
        removeWhenEmpty: Bool,
        persistedGeometryData: Data?
    ) {
        persistor.persist(
            snapshot,
            removeWhenEmpty: removeWhenEmpty,
            persistedGeometryData: persistedGeometryData,
            synchronously: true
        )
    }
}
