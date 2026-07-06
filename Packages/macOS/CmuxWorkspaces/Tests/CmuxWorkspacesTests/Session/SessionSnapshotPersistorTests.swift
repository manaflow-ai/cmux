import Foundation
import Testing
@testable import CmuxWorkspaces

/// Minimal session-snapshot root for persistor tests.
private struct SnapshotFixture: SessionSnapshotRepresenting, Equatable {
    var version: Int
    var hasWindows: Bool
}

/// Minimal geometry payload for persistor tests.
private struct GeometryFixture: WindowGeometryPersisting, Equatable {
    var version: Int
}

// UserDefaults is thread-safe; this wrapper lets @Sendable marker callbacks
// mutate a suite-scoped test defaults without touching global state.
private struct MarkerFixture: @unchecked Sendable {
    let defaults: UserDefaults
    let key = "cmux.session.crashOnlyPrimarySnapshotRemoval.test"

    func mark() {
        defaults.set(true, forKey: key)
    }

    func clear() {
        defaults.removeObject(forKey: key)
    }

    var isMarked: Bool {
        defaults.bool(forKey: key)
    }
}

@Suite("SessionSnapshotPersistor")
struct SessionSnapshotPersistorTests {
    private let snapshotKey = "cmux.session.snapshot.v1"
    private let geometryKey = "cmux.session.geometry.v2"
    private let legacyGeometryKey = "cmux.session.geometry.v1"

    private func makeDefaults() -> UserDefaults {
        let suite = "cmux-persistor-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    private func makePersistor(
        appSupport: URL,
        geometryDefaults: UserDefaults,
        synchronousQueue: DispatchQueue,
        marker: MarkerFixture? = nil
    ) -> SessionSnapshotPersistor<SnapshotFixture, GeometryFixture> {
        let snapshotStore = SessionSnapshotRepository<SnapshotFixture>(
            schemaVersion: 1,
            bundleIdentifier: "com.cmuxterm.tests",
            appSupportDirectory: appSupport
        )
        let geometryStore = WindowGeometryStore<GeometryFixture>(
            schemaVersion: 2,
            defaultsKey: geometryKey,
            legacyDefaultsKeys: [legacyGeometryKey]
        )
        return SessionSnapshotPersistor(
            snapshotStore: snapshotStore,
            geometryStore: geometryStore,
            geometryDefaults: geometryDefaults,
            queue: synchronousQueue,
            markCrashOnlyPrimarySnapshotRemoval: {
                marker?.mark()
            },
            clearCrashOnlyPrimarySnapshotRemovalMarker: {
                marker?.clear()
            }
        )
    }

    private func makeTempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-persistor-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("synchronous persist writes geometry data then saves the snapshot")
    func synchronousWrite() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let defaults = makeDefaults()
        let queue = DispatchQueue(label: "unused")
        let persistor = makePersistor(appSupport: dir, geometryDefaults: defaults, synchronousQueue: queue)

        let geometryData = try JSONEncoder().encode(GeometryFixture(version: 2))
        persistor.persist(
            SnapshotFixture(version: 1, hasWindows: true),
            removeWhenEmpty: false,
            persistedGeometryData: geometryData,
            synchronously: true
        )

        #expect(defaults.data(forKey: geometryKey) == geometryData)
        let snapshotStore = SessionSnapshotRepository<SnapshotFixture>(
            schemaVersion: 1,
            bundleIdentifier: "com.cmuxterm.tests",
            appSupportDirectory: dir
        )
        #expect(snapshotStore.load(fileURL: nil) == SnapshotFixture(version: 1, hasWindows: true))
    }

    @Test("nil geometry data clears the legacy geometry keys")
    func clearsLegacyGeometryKeys() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let defaults = makeDefaults()
        defaults.set(Data([0x01]), forKey: legacyGeometryKey)
        let persistor = makePersistor(appSupport: dir, geometryDefaults: defaults, synchronousQueue: DispatchQueue(label: "unused"))

        persistor.persist(
            SnapshotFixture(version: 1, hasWindows: true),
            removeWhenEmpty: false,
            persistedGeometryData: nil,
            synchronously: true
        )

        #expect(defaults.data(forKey: legacyGeometryKey) == nil)
    }

    @Test("nil snapshot with removeWhenEmpty removes the snapshot file")
    func removeWhenEmptyRemovesSnapshot() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let defaults = makeDefaults()
        let snapshotStore = SessionSnapshotRepository<SnapshotFixture>(
            schemaVersion: 1,
            bundleIdentifier: "com.cmuxterm.tests",
            appSupportDirectory: dir
        )
        _ = snapshotStore.save(SnapshotFixture(version: 1, hasWindows: true), fileURL: nil)
        #expect(snapshotStore.load(fileURL: nil) != nil)

        let persistor = makePersistor(appSupport: dir, geometryDefaults: defaults, synchronousQueue: DispatchQueue(label: "unused"))
        persistor.persist(
            nil,
            removeWhenEmpty: true,
            persistedGeometryData: nil,
            synchronously: true
        )

        #expect(snapshotStore.load(fileURL: nil) == nil)
    }

    @Test("saving a snapshot clears the crash-only primary removal marker")
    func savingSnapshotClearsCrashOnlyRemovalMarker() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let defaults = makeDefaults()
        let marker = MarkerFixture(defaults: defaults)
        marker.mark()
        let persistor = makePersistor(
            appSupport: dir,
            geometryDefaults: defaults,
            synchronousQueue: DispatchQueue(label: "unused"),
            marker: marker
        )

        persistor.persist(
            SnapshotFixture(version: 1, hasWindows: true),
            removeWhenEmpty: false,
            persistedGeometryData: nil,
            synchronously: true
        )

        #expect(!marker.isMarked)
    }

    @Test("crash-only empty primary removal marks backup preservation")
    func crashOnlyRemovalMarksBackupPreservation() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let defaults = makeDefaults()
        let marker = MarkerFixture(defaults: defaults)
        let snapshotStore = SessionSnapshotRepository<SnapshotFixture>(
            schemaVersion: 1,
            bundleIdentifier: "com.cmuxterm.tests",
            appSupportDirectory: dir
        )
        _ = snapshotStore.save(SnapshotFixture(version: 1, hasWindows: true), fileURL: nil)
        let persistor = makePersistor(
            appSupport: dir,
            geometryDefaults: defaults,
            synchronousQueue: DispatchQueue(label: "unused"),
            marker: marker
        )

        persistor.persist(
            nil,
            removeWhenEmpty: true,
            persistedGeometryData: nil,
            synchronously: true,
            preserveManualRestoreBackupOnMissingPrimary: true
        )

        #expect(snapshotStore.load(fileURL: nil) == nil)
        #expect(marker.isMarked)
    }

    @Test("nothing to write is a no-op: snapshot file and geometry key untouched")
    func nothingToWriteIsNoOp() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let defaults = makeDefaults()
        let snapshotStore = SessionSnapshotRepository<SnapshotFixture>(
            schemaVersion: 1,
            bundleIdentifier: "com.cmuxterm.tests",
            appSupportDirectory: dir
        )
        _ = snapshotStore.save(SnapshotFixture(version: 1, hasWindows: true), fileURL: nil)
        defaults.set(Data([0x09]), forKey: legacyGeometryKey)

        let persistor = makePersistor(appSupport: dir, geometryDefaults: defaults, synchronousQueue: DispatchQueue(label: "unused"))
        persistor.persist(
            nil,
            removeWhenEmpty: false,
            persistedGeometryData: nil,
            synchronously: true
        )

        // Early return: the existing snapshot survives and the legacy key the
        // geometry branch would have cleared is untouched.
        #expect(snapshotStore.load(fileURL: nil) != nil)
        #expect(defaults.data(forKey: legacyGeometryKey) == Data([0x09]))
    }

    @Test("queued persist eventually writes through the serial queue")
    func queuedWrite() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let defaults = makeDefaults()
        let queue = DispatchQueue(label: "cmux-persistor-tests-queued")
        let persistor = makePersistor(appSupport: dir, geometryDefaults: defaults, synchronousQueue: queue)

        let geometryData = try JSONEncoder().encode(GeometryFixture(version: 2))
        persistor.persist(
            SnapshotFixture(version: 1, hasWindows: true),
            removeWhenEmpty: false,
            persistedGeometryData: geometryData,
            synchronously: false
        )

        // Drain the serial queue: a sync barrier after the async write returns
        // only once the write block has run.
        queue.sync {}
        #expect(defaults.data(forKey: geometryKey) == geometryData)
    }
}
