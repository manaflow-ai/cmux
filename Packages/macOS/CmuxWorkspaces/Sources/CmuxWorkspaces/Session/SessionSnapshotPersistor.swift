public import Foundation

/// Coordinates the one write block that persists a session snapshot and its
/// primary-window geometry together.
///
/// Faithful lift of the `AppDelegate.persistSessionSnapshot(_:removeWhenEmpty:
/// persistedGeometryData:synchronously:)` body plus the private
/// `sessionPersistenceQueue` serial queue it dispatched onto. The persistor owns
/// the snapshot store, the geometry store, the geometry `UserDefaults`, and the
/// serial queue, and exposes one `persist` method whose body is byte-identical
/// to the legacy write block: the early-return guard (nothing to write), the
/// geometry branch (`saveEncoded` when geometry data is present, else
/// `removeLegacy`), the snapshot branch (`save` when present, else
/// `removeSnapshot` only when `removeWhenEmpty`), and the synchronous-vs-queued
/// dispatch decision. The geometry and snapshot stores still own the actual
/// wire format and `UserDefaults`/file access; this type only sequences the two
/// writes and chooses the dispatch lane.
///
/// **Isolation.** `Sendable`, dispatch-queue-confined work, no actor. The write
/// block escapes to the injected serial queue (`qos: .utility`) on the queued
/// path exactly as the legacy code did, so every member it captures must be
/// `Sendable`: both stores are `Sendable` value types, `UserDefaults` and
/// `DispatchQueue` are `Sendable`. There is no mutable state to protect, and the
/// synchronous path runs inline on the caller's thread (the terminating
/// scrollback save on the main actor) just as before. Co-locating the queue with
/// the two stores it feeds turns the legacy god-file `writeBlock` closure into a
/// plain method call.
///
/// **Single source of truth for the geometry store.** The geometry store is a
/// `Sendable` value; the composition root passes the same-configured store it
/// uses for the non-snapshot geometry reads/writes, so the FROZEN defaults key
/// and schema version stay owned at one place. Passing it by value cannot
/// diverge because the store is stateless configuration.
public struct SessionSnapshotPersistor<SnapshotValue: SessionSnapshotRepresenting, GeometryPayload: WindowGeometryPersisting>: Sendable {
    private let snapshotStore: any SessionSnapshotStoring<SnapshotValue>
    private let geometryStore: WindowGeometryStore<GeometryPayload>
    // Justification: `UserDefaults` is documented thread-safe ("thread-safe")
    // but Foundation does not mark it `Sendable`. The legacy write block
    // captured `.standard` directly across the same serial queue; this is the
    // identical access pattern, so `nonisolated(unsafe)` records that the
    // unchecked capture is intentional and behaviorally unchanged.
    private nonisolated(unsafe) let geometryDefaults: UserDefaults
    private let queue: DispatchQueue

    /// Creates a persistor.
    ///
    /// - Parameters:
    ///   - snapshotStore: the session-snapshot file store (the production
    ///     conformer is ``SessionSnapshotRepository``).
    ///   - geometryStore: the primary-window geometry store; pass the same
    ///     value the composition root uses for non-snapshot geometry writes so
    ///     the FROZEN defaults key and schema version stay single-sourced.
    ///   - geometryDefaults: the `UserDefaults` the geometry store writes to
    ///     (the legacy write block used `.standard`).
    ///   - queue: the serial queue the queued (asynchronous) write dispatches
    ///     onto. Pass the legacy `com.cmuxterm.app.sessionPersistence`
    ///     `qos: .utility` queue.
    public init(
        snapshotStore: any SessionSnapshotStoring<SnapshotValue>,
        geometryStore: WindowGeometryStore<GeometryPayload>,
        geometryDefaults: UserDefaults,
        queue: DispatchQueue
    ) {
        self.snapshotStore = snapshotStore
        self.geometryStore = geometryStore
        self.geometryDefaults = geometryDefaults
        self.queue = queue
    }

    /// Persists `snapshot` and the primary-window geometry in one write block.
    ///
    /// Byte-identical to the legacy `persistSessionSnapshot`: returns early when
    /// there is nothing to write (no snapshot, not removing, no geometry data);
    /// otherwise writes the geometry (encoded data when present, else clears the
    /// legacy keys), then the snapshot (saved when present, removed only when
    /// `removeWhenEmpty`). The block runs inline when `synchronously` is true (so
    /// the terminating scrollback save lands before the process exits), else it
    /// is dispatched onto the serial queue.
    ///
    /// - Parameters:
    ///   - snapshot: the snapshot to write, or nil to clear it.
    ///   - removeWhenEmpty: when `snapshot` is nil, whether to remove the
    ///     existing snapshot file (a no-op snapshot save otherwise leaves it).
    ///   - persistedGeometryData: the already-encoded primary-window geometry,
    ///     or nil to clear the legacy geometry keys.
    ///   - synchronously: whether to run the write inline (true) or queue it.
    public func persist(
        _ snapshot: SnapshotValue?,
        removeWhenEmpty: Bool,
        persistedGeometryData: Data?,
        synchronously: Bool
    ) {
        guard snapshot != nil || removeWhenEmpty || persistedGeometryData != nil else { return }

        let snapshotStore = self.snapshotStore
        let geometryStore = self.geometryStore
        // Justification: see the stored-property note. `.standard` is the
        // process-global defaults the legacy write block captured directly.
        nonisolated(unsafe) let geometryDefaults = self.geometryDefaults
        let writeBlock: @Sendable () -> Void = {
            if let persistedGeometryData {
                geometryStore.saveEncoded(persistedGeometryData, defaults: geometryDefaults)
            } else {
                geometryStore.removeLegacy(defaults: geometryDefaults)
            }
            if let snapshot {
                _ = snapshotStore.save(snapshot, fileURL: nil)
            } else if removeWhenEmpty {
                snapshotStore.removeSnapshot(fileURL: nil)
            }
        }

        if synchronously {
            writeBlock()
        } else {
            queue.async(execute: writeBlock)
        }
    }
}
