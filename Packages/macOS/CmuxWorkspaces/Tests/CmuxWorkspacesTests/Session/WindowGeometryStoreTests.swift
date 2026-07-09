import Foundation
import Testing
@testable import CmuxWorkspaces

/// Minimal stand-in for the app's `PersistedWindowGeometry` payload: a version
/// plus an opaque frame field, mirroring the only field the store's usability
/// rules read.
private struct GeometryFixture: WindowGeometryPersisting, Equatable {
    var version: Int
    var x: Double
}

@Suite("WindowGeometryStore")
struct WindowGeometryStoreTests {
    private let schemaVersion = 2
    private let currentKey = "cmux.session.lastWindowGeometry.v2"
    private let legacyKeys = ["cmux.session.lastWindowGeometry.v1"]

    private func makeStore() -> WindowGeometryStore<GeometryFixture> {
        WindowGeometryStore(
            schemaVersion: schemaVersion,
            defaultsKey: currentKey,
            legacyDefaultsKeys: legacyKeys
        )
    }

    private func makeDefaults() -> UserDefaults {
        let defaults = UserDefaults(suiteName: "cmux-geometry-tests-\(UUID().uuidString)")!
        return defaults
    }

    @Test("save then load round-trips the payload")
    func saveLoadRoundTrip() {
        let store = makeStore()
        let defaults = makeDefaults()
        let payload = GeometryFixture(version: schemaVersion, x: 42.5)

        store.save(payload, defaults: defaults)
        #expect(store.load(defaults: defaults) == payload)
    }

    @Test("load returns nil when no payload was written")
    func loadMissing() {
        #expect(makeStore().load(defaults: makeDefaults()) == nil)
    }

    @Test("a wrong-version entry is discarded and removed on load")
    func versionMismatchDiscarded() {
        let store = makeStore()
        let defaults = makeDefaults()
        let mismatched = GeometryFixture(version: schemaVersion + 1, x: 1)
        let data = try? JSONEncoder().encode(mismatched)
        defaults.set(data, forKey: currentKey)

        #expect(store.load(defaults: defaults) == nil)
        #expect(defaults.data(forKey: currentKey) == nil)
    }

    @Test("corrupt data is discarded and removed on load")
    func corruptDataDiscarded() {
        let store = makeStore()
        let defaults = makeDefaults()
        defaults.set(Data([0x00, 0x01, 0x02]), forKey: currentKey)

        #expect(store.load(defaults: defaults) == nil)
        #expect(defaults.data(forKey: currentKey) == nil)
    }

    @Test("every read and write removes the legacy keys")
    func legacyKeysRemoved() {
        let store = makeStore()
        let defaults = makeDefaults()
        defaults.set(Data([0xFF]), forKey: legacyKeys[0])

        _ = store.load(defaults: defaults)
        #expect(defaults.data(forKey: legacyKeys[0]) == nil)

        defaults.set(Data([0xFF]), forKey: legacyKeys[0])
        store.save(GeometryFixture(version: schemaVersion, x: 9), defaults: defaults)
        #expect(defaults.data(forKey: legacyKeys[0]) == nil)
    }

    @Test("saveEncoded writes raw data that load decodes back")
    func saveEncodedRoundTrip() {
        let store = makeStore()
        let defaults = makeDefaults()
        let payload = GeometryFixture(version: schemaVersion, x: 7)
        let data = try? JSONEncoder().encode(payload)

        store.saveEncoded(data!, defaults: defaults)
        #expect(store.load(defaults: defaults) == payload)
    }

    @Test("encode/decode is byte-faithful and version-gated")
    func encodeDecodeFaithful() {
        let store = makeStore()
        let payload = GeometryFixture(version: schemaVersion, x: 3.25)
        let data = store.encode(payload)
        #expect(data == (try? JSONEncoder().encode(payload)))
        #expect(store.decode(data!) == payload)
        let wrongVersion = try? JSONEncoder().encode(GeometryFixture(version: 99, x: 0))
        #expect(store.decode(wrongVersion!) == nil)
    }
}
