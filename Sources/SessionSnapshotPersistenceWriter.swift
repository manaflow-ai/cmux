import CmuxFoundation
import Foundation
import CmuxWorkspaces

/// Owns the durable write side of the application session snapshot.
///
/// Snapshot construction and restore remain in `AppDelegate`, but the file
/// write, geometry cache write, and crash-recovery marker all follow the same
/// synchronous/asynchronous rules and belong behind this small seam.
// The store is Sendable by contract and the queue is immutable; the unchecked
// conformance only accounts for Foundation's DispatchQueue annotation on the
// deployment SDK. All mutable persistence work is serialized by `queue`.
struct SessionSnapshotPersistenceWriter: @unchecked Sendable {
    typealias Store = any SessionSnapshotStoring<AppSessionSnapshot>

    private let store: Store
    private let defaults: UserDefaults
    private let queue: DispatchQueue
    private let targetQueue: DispatchQueue

    init(
        store: Store,
        queue: DispatchQueue,
        defaults: UserDefaults = .standard
    ) {
        self.store = store
        self.defaults = defaults
        self.targetQueue = queue
        // Own serial ordering even if the supplied scheduling target is concurrent.
        self.queue = DispatchQueue(
            label: "com.cmuxterm.app.sessionPersistence.writer",
            qos: .utility,
            target: queue
        )
    }

    var snapshotStore: Store { store }

    func persist(
        _ snapshot: AppSessionSnapshot?,
        removeWhenEmpty: Bool,
        persistedGeometryData: Data?,
        synchronously: Bool,
        preserveManualRestoreBackupOnMissingPrimary: Bool = false
    ) {
        guard snapshot != nil || removeWhenEmpty || persistedGeometryData != nil else { return }

        // Persistence can outlive its main-actor owner; retain only the Sendable
        // store and defaults so finishing a write cannot destroy AppDelegate on this queue.
        let writeBlock = { [store, defaults] in
            // Autosave runs every few seconds. Only write defaults that changed:
            // each set/remove posts didChangeNotification even when it is a no-op,
            // waking every defaults observer and SwiftUI's @AppStorage lock.
            Self.removeLegacyPersistedWindowGeometry(defaults: defaults)
            if let persistedGeometryData {
                defaults.setIfChanged(
                    persistedGeometryData,
                    forKey: Self.persistedWindowGeometryDefaultsKey
                )
            }
            if let snapshot {
                if store.save(snapshot, fileURL: nil) {
                    Self.clearCrashOnlyPrimarySnapshotRemovalMarker(defaults: defaults)
                }
            } else if removeWhenEmpty {
                if preserveManualRestoreBackupOnMissingPrimary {
                    Self.markCrashOnlyPrimarySnapshotRemoval(defaults: defaults)
                } else {
                    Self.clearCrashOnlyPrimarySnapshotRemovalMarker(defaults: defaults)
                }
                store.removeSnapshot(fileURL: nil)
            }
        }

        if synchronously {
            // Calling from this executor or its target would deadlock the drain.
            dispatchPrecondition(condition: .notOnQueue(targetQueue))
            queue.sync(execute: writeBlock)
        } else {
            queue.async(execute: writeBlock)
        }
    }

    static let persistedWindowGeometryDefaultsKey = "cmux.session.lastWindowGeometry.v2"
    private static let legacyPersistedWindowGeometryDefaultsKeys = [
        "cmux.session.lastWindowGeometry.v1"
    ]
    private static let crashOnlyPrimarySnapshotRemovalDefaultsKey =
        "cmux.session.crashOnlyPrimarySnapshotRemoval.v1"

    static func removeLegacyPersistedWindowGeometry(defaults: UserDefaults = .standard) {
        legacyPersistedWindowGeometryDefaultsKeys.forEach { defaults.removeObjectIfPresent(forKey: $0) }
    }

    static func markCrashOnlyPrimarySnapshotRemoval(defaults: UserDefaults = .standard) {
        defaults.setIfChanged(true, forKey: crashOnlyPrimarySnapshotRemovalDefaultsKey)
    }

    static func hasCrashOnlyPrimarySnapshotRemovalMarker(defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: crashOnlyPrimarySnapshotRemovalDefaultsKey)
    }

    static func clearCrashOnlyPrimarySnapshotRemovalMarker(defaults: UserDefaults = .standard) {
        // Called on every autosave write; skip the no-op removal notification.
        defaults.removeObjectIfPresent(forKey: crashOnlyPrimarySnapshotRemovalDefaultsKey)
    }
}
