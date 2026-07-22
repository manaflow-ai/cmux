import Foundation
import Testing
@testable import CmuxSettings

@Suite("JSONConfigStore")
struct JSONConfigStoreTests {
    private func makeStore() -> (JSONConfigStore, URL, SettingCatalog) {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-settings-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let fileURL = tempDir.appendingPathComponent("cmux.json", isDirectory: false)
        return (JSONConfigStore(fileURL: fileURL), fileURL, SettingCatalog())
    }

    @Test func readsDefaultWhenFileMissing() async {
        let (store, _, _) = makeStore()
        let value = await store.value(for: JSONKey<String>(id: "automation.socketPassword", defaultValue: ""))
        #expect(value == "")
    }

    @Test func roundTripsNestedKey() async throws {
        let (store, fileURL, _) = makeStore()
        try await store.set("hunter2", for: JSONKey<String>(id: "automation.socketPassword", defaultValue: ""))
        let value = await store.value(for: JSONKey<String>(id: "automation.socketPassword", defaultValue: ""))
        #expect(value == "hunter2")

        let data = try Data(contentsOf: fileURL)
        let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let automation = parsed?["automation"] as? [String: Any]
        #expect(automation?["socketPassword"] as? String == "hunter2")
    }

    @Test func resetRemovesEntryAndPrunesEmptyParents() async throws {
        let (store, fileURL, _) = makeStore()
        try await store.set("hunter2", for: JSONKey<String>(id: "automation.socketPassword", defaultValue: ""))
        try await store.reset(JSONKey<String>(id: "automation.socketPassword", defaultValue: ""))
        let value = await store.value(for: JSONKey<String>(id: "automation.socketPassword", defaultValue: ""))
        #expect(value == "")
        let data = try Data(contentsOf: fileURL)
        let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(parsed?["automation"] == nil)
    }

    @Test func toleratesJSONCComments() async throws {
        let (store, fileURL, _) = makeStore()
        let json = """
        {
          // commented
          "automation": {
            "socketPassword": "test",
          }
        }
        """
        try Data(json.utf8).write(to: fileURL)
        let value = await store.value(for: JSONKey<String>(id: "automation.socketPassword", defaultValue: ""))
        #expect(value == "test")
    }

    @Test func observesExternalEdit() async throws {
        let (store, fileURL, _) = makeStore()
        try Data("{}".utf8).write(to: fileURL)

        let key = JSONKey<String>(id: "automation.socketPassword", defaultValue: "")
        let payload = #"{"automation":{"socketPassword":"injected"}}"#

        // Ready-handshake, used by every observation test here: wait for the
        // observer to consume the initial value before any external activity,
        // so the first collected element never races the writer.
        let (ready, readyContinuation) = AsyncStream<Void>.makeStream()
        let observed = Task<[String], Never> {
            var collected: [String] = []
            for await value in store.values(for: key) {
                collected.append(value)
                if collected.count == 1 { readyContinuation.yield() }
                if collected.last == "injected" { break }
            }
            return collected
        }

        await withTimeout(seconds: 8) {
            var it = ready.makeAsyncIterator()
            _ = await it.next()
        }

        let writer = Task {
            var bump = Date()
            while !Task.isCancelled {
                try? Data(payload.utf8).write(to: fileURL)
                bump = bump.addingTimeInterval(1)
                try? FileManager.default.setAttributes(
                    [.modificationDate: bump], ofItemAtPath: fileURL.path
                )
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
        }

        let collected = await withTimeout(seconds: 8) { await observed.value }
        writer.cancel()
        #expect(collected.first == "")
        #expect(collected.last == "injected")
    }

    @Test func snapshotReflectsWrites() async throws {
        let (store, _, _) = makeStore()
        let key = JSONKey<String>(id: "app.devWindowDisplay", defaultValue: "")
        #expect(store.snapshotValue(for: key) == "")

        try await store.set("LG HDR 4K", for: key)
        #expect(store.snapshotValue(for: key) == "LG HDR 4K")

        try await store.reset(key)
        #expect(store.snapshotValue(for: key) == "")
    }

    @Test func snapshotMatchesAsyncRead() async throws {
        let (store, _, _) = makeStore()
        let key = JSONKey<String>(id: "automation.socketPassword", defaultValue: "")
        try await store.set("hunter2", for: key)
        let async = await store.value(for: key)
        #expect(store.snapshotValue(for: key) == async)
    }

    @Test func snapshotReadsOnDiskValueForFreshStore() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-settings-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let fileURL = tempDir.appendingPathComponent("cmux.json", isDirectory: false)
        let payload = #"{"app":{"devWindowDisplay":"LG HDR 4K"}}"#
        try Data(payload.utf8).write(to: fileURL)

        // Brand-new store, no async read first: the synchronous read goes
        // straight to disk and reflects the on-disk value.
        let store = JSONConfigStore(fileURL: fileURL)
        let key = JSONKey<String>(id: "app.devWindowDisplay", defaultValue: "")
        #expect(store.snapshotValue(for: key) == "LG HDR 4K")
    }

    @Test func snapshotReflectsExternalEdit() async throws {
        let (store, fileURL, _) = makeStore()
        let key = JSONKey<String>(id: "app.devWindowDisplay", defaultValue: "")
        #expect(store.snapshotValue(for: key) == "")

        // A direct disk read picks up an external edit immediately, with no
        // observer subscription or actor round-trip.
        try Data(#"{"app":{"devWindowDisplay":"LG HDR 4K"}}"#.utf8).write(to: fileURL)
        #expect(store.snapshotValue(for: key) == "LG HDR 4K")
    }

    @Test func devWindowDisplayCatalogKeyRoundTripsToSharedPath() async throws {
        let (store, fileURL, catalog) = makeStore()
        try await store.set("LG HDR 4K", for: catalog.app.devWindowDisplay)

        // Async and sync reads agree on the catalog key.
        #expect(await store.value(for: catalog.app.devWindowDisplay) == "LG HDR 4K")
        #expect(store.snapshotValue(for: catalog.app.devWindowDisplay) == "LG HDR 4K")

        // It lands at app.devWindowDisplay in cmux.json — the shared on-disk
        // shape the CLI, the app's window hook, and the Debug menu all read.
        let parsed = try JSONSerialization.jsonObject(with: Data(contentsOf: fileURL)) as? [String: Any]
        let app = parsed?["app"] as? [String: Any]
        #expect(app?["devWindowDisplay"] as? String == "LG HDR 4K")

        try await store.reset(catalog.app.devWindowDisplay)
        #expect(store.snapshotValue(for: catalog.app.devWindowDisplay) == "")
    }

}
