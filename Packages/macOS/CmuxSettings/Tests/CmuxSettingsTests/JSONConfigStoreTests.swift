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

        // The observer Task owns its own iterator. It reports through a
        // ready-stream the instant it consumes the initial ("") value, then keeps
        // collecting until it sees the injected value.
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

        // Wait for the observer to consume the initial value before any external
        // write, so the first collected element is deterministically "" rather
        // than racing a writer that could land "injected" before the initial read.
        await withTimeout(seconds: 8) {
            var it = ready.makeAsyncIterator()
            _ = await it.next()
        }

        // The producer yields that initial value just before it finishes
        // registering the subscriber on the actor, so the first filesystem event
        // can still race that registration. Instead of betting a single
        // wall-clock sleep, run a concurrent writer that re-applies the same
        // external edit on a loop, bumping the file's modification date each pass.
        // Each re-touch produces a fresh DispatchSource event that is delivered
        // once the watcher is armed. The bytes (and thus the asserted value) are
        // identical every pass, so this only closes the readiness race without
        // weakening the assertion.
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

    @Test func writesThroughSymlinkWithoutReplacingIt() async throws {
        // A cmux.json symlinked into a dotfiles repo must survive writes: the
        // atomic write (temp-file + rename) has to land on the link *target*,
        // not clobber the link itself and turn it into a standalone file.
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-settings-symlink-\(UUID().uuidString)", isDirectory: true)
        let repoDir = tempDir.appendingPathComponent("repo", isDirectory: true)
        try FileManager.default.createDirectory(at: repoDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let targetURL = repoDir.appendingPathComponent("cmux.json", isDirectory: false)
        try Data("{}".utf8).write(to: targetURL)

        let linkURL = tempDir.appendingPathComponent("cmux.json", isDirectory: false)
        try FileManager.default.createSymbolicLink(at: linkURL, withDestinationURL: targetURL)

        let store = JSONConfigStore(fileURL: linkURL)
        let key = JSONKey<String>(id: "app.appearance", defaultValue: "")
        try await store.set("dark", for: key)

        // The link path is still a symlink — not replaced by a regular file.
        let linkAttributes = try FileManager.default.attributesOfItem(atPath: linkURL.path)
        #expect(linkAttributes[.type] as? FileAttributeType == .typeSymbolicLink)

        // The write landed on the target file, so reading through either the
        // target or the store reflects the new value.
        let targetData = try Data(contentsOf: targetURL)
        let parsed = try JSONSerialization.jsonObject(with: targetData) as? [String: Any]
        let app = parsed?["app"] as? [String: Any]
        #expect(app?["appearance"] as? String == "dark")
        #expect(await store.value(for: key) == "dark")
    }

    @Test func writesThroughRelativeSymlinkDestination() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-settings-symlink-\(UUID().uuidString)", isDirectory: true)
        let repoDir = tempDir.appendingPathComponent("repo", isDirectory: true)
        try FileManager.default.createDirectory(at: repoDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let targetURL = repoDir.appendingPathComponent("cmux.json", isDirectory: false)
        try Data("{}".utf8).write(to: targetURL)

        let linkURL = tempDir.appendingPathComponent("cmux.json", isDirectory: false)
        try FileManager.default.createSymbolicLink(
            atPath: linkURL.path,
            withDestinationPath: "repo/cmux.json"
        )

        let store = JSONConfigStore(fileURL: linkURL)
        let key = JSONKey<String>(id: "app.appearance", defaultValue: "")
        try await store.set("dark", for: key)

        let linkAttributes = try FileManager.default.attributesOfItem(atPath: linkURL.path)
        #expect(linkAttributes[.type] as? FileAttributeType == .typeSymbolicLink)

        let targetData = try Data(contentsOf: targetURL)
        let parsed = try JSONSerialization.jsonObject(with: targetData) as? [String: Any]
        let app = parsed?["app"] as? [String: Any]
        #expect(app?["appearance"] as? String == "dark")
        #expect(await store.value(for: key) == "dark")
    }

    @Test func writesThroughDanglingSymlinkCreatesTarget() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-settings-symlink-\(UUID().uuidString)", isDirectory: true)
        let repoDir = tempDir.appendingPathComponent("repo", isDirectory: true)
        try FileManager.default.createDirectory(at: repoDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let targetURL = repoDir.appendingPathComponent("cmux.json", isDirectory: false)
        let linkURL = tempDir.appendingPathComponent("cmux.json", isDirectory: false)
        try FileManager.default.createSymbolicLink(at: linkURL, withDestinationURL: targetURL)

        let store = JSONConfigStore(fileURL: linkURL)
        let key = JSONKey<String>(id: "app.appearance", defaultValue: "")
        try await store.set("dark", for: key)

        let linkAttributes = try FileManager.default.attributesOfItem(atPath: linkURL.path)
        #expect(linkAttributes[.type] as? FileAttributeType == .typeSymbolicLink)

        #expect(FileManager.default.fileExists(atPath: targetURL.path))
        let targetAttributes = try FileManager.default.attributesOfItem(atPath: targetURL.path)
        #expect(targetAttributes[.type] as? FileAttributeType == .typeRegular)

        let targetData = try Data(contentsOf: targetURL)
        let parsed = try JSONSerialization.jsonObject(with: targetData) as? [String: Any]
        let app = parsed?["app"] as? [String: Any]
        #expect(app?["appearance"] as? String == "dark")
        #expect(await store.value(for: key) == "dark")
    }

    @Test func writesThroughSymlinkChainToFinalTarget() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-settings-symlink-\(UUID().uuidString)", isDirectory: true)
        let repoDir = tempDir.appendingPathComponent("repo", isDirectory: true)
        try FileManager.default.createDirectory(at: repoDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let targetURL = repoDir.appendingPathComponent("cmux.json", isDirectory: false)
        try Data("{}".utf8).write(to: targetURL)

        let midURL = tempDir.appendingPathComponent("mid.json", isDirectory: false)
        try FileManager.default.createSymbolicLink(at: midURL, withDestinationURL: targetURL)

        let linkURL = tempDir.appendingPathComponent("cmux.json", isDirectory: false)
        try FileManager.default.createSymbolicLink(at: linkURL, withDestinationURL: midURL)

        let store = JSONConfigStore(fileURL: linkURL)
        let key = JSONKey<String>(id: "app.appearance", defaultValue: "")
        try await store.set("dark", for: key)

        let linkAttributes = try FileManager.default.attributesOfItem(atPath: linkURL.path)
        #expect(linkAttributes[.type] as? FileAttributeType == .typeSymbolicLink)

        let midAttributes = try FileManager.default.attributesOfItem(atPath: midURL.path)
        #expect(midAttributes[.type] as? FileAttributeType == .typeSymbolicLink)

        let targetData = try Data(contentsOf: targetURL)
        let parsed = try JSONSerialization.jsonObject(with: targetData) as? [String: Any]
        let app = parsed?["app"] as? [String: Any]
        #expect(app?["appearance"] as? String == "dark")
        #expect(await store.value(for: key) == "dark")
    }
}

private func withTimeout<T: Sendable>(seconds: Double, _ work: @escaping @Sendable () async -> T) async -> T {
    await withTaskGroup(of: T?.self) { group in
        group.addTask { await work() }
        group.addTask {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            return nil
        }
        for await result in group {
            if let result {
                group.cancelAll()
                return result
            }
        }
        fatalError("timed out without producing a value")
    }
}
