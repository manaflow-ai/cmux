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

    private func makeSymlinkFixture() throws -> (tempDir: URL, repoDir: URL, targetURL: URL, linkURL: URL) {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-settings-symlink-\(UUID().uuidString)", isDirectory: true)
        let repoDir = tempDir.appendingPathComponent("repo", isDirectory: true)
        try FileManager.default.createDirectory(at: repoDir, withIntermediateDirectories: true)
        return (tempDir, repoDir, repoDir.appendingPathComponent("cmux.json"), tempDir.appendingPathComponent("cmux.json"))
    }

    private func assertSymlinkWriteThrough(
        store: JSONConfigStore, linkURL: URL, targetURL: URL, key: JSONKey<String>, expected: String
    ) async throws {
        let linkAttributes = try FileManager.default.attributesOfItem(atPath: linkURL.path)
        #expect(linkAttributes[.type] as? FileAttributeType == .typeSymbolicLink)
        let targetData = try Data(contentsOf: targetURL)
        let parsed = try JSONSerialization.jsonObject(with: targetData) as? [String: Any]
        let app = parsed?["app"] as? [String: Any]
        #expect(app?["appearance"] as? String == expected)
        #expect(await store.value(for: key) == expected)
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

    @Test func observesExternalEditThroughSymlinkTarget() async throws {
        let fixture = try makeSymlinkFixture()
        defer { try? FileManager.default.removeItem(at: fixture.tempDir) }
        try Data("{}".utf8).write(to: fixture.targetURL)
        try FileManager.default.createSymbolicLink(at: fixture.linkURL, withDestinationURL: fixture.targetURL)

        let store = JSONConfigStore(fileURL: fixture.linkURL)
        let key = JSONKey<String>(id: "automation.socketPassword", defaultValue: "")
        let payload = #"{"automation":{"socketPassword":"injected"}}"#
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
        let writer = retouchingWriter(payload: payload, fileURL: fixture.targetURL)
        let collected = await observedValues(observed)
        writer.cancel()
        #expect(collected.first == "")
        #expect(collected.last == "injected")
    }

    @Test func observesRetargetedSymlinkAndWritesToNewTarget() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-settings-symlink-\(UUID().uuidString)", isDirectory: true)
        let repoA = tempDir.appendingPathComponent("repoA", isDirectory: true)
        let repoB = tempDir.appendingPathComponent("repoB", isDirectory: true)
        try FileManager.default.createDirectory(at: repoA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: repoB, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let targetA = repoA.appendingPathComponent("cmux.json", isDirectory: false)
        let targetB = repoB.appendingPathComponent("cmux.json", isDirectory: false)
        try Data(#"{"app":{"appearance":"light"}}"#.utf8).write(to: targetA)
        try Data(#"{"app":{"appearance":"blue"},"other":{"keep":true}}"#.utf8).write(to: targetB)
        let linkURL = tempDir.appendingPathComponent("cmux.json", isDirectory: false)
        try FileManager.default.createSymbolicLink(at: linkURL, withDestinationURL: targetA)
        let store = JSONConfigStore(fileURL: linkURL)
        let key = JSONKey<String>(id: "app.appearance", defaultValue: "")
        let (ready, readyContinuation) = AsyncStream<Void>.makeStream()
        let observed = Task<[String], Never> {
            var collected: [String] = []
            for await value in store.values(for: key) {
                collected.append(value)
                if collected.count == 1 { readyContinuation.yield() }
                if collected.last == "blue" { break }
            }
            return collected
        }
        await withTimeout(seconds: 8) {
            var it = ready.makeAsyncIterator()
            _ = await it.next()
        }
        let writer = Task {
            while !Task.isCancelled {
                try? FileManager.default.removeItem(at: linkURL)
                try? FileManager.default.createSymbolicLink(at: linkURL, withDestinationURL: targetB)
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
        }
        let collected = await observedValues(observed)
        writer.cancel()
        _ = await writer.value
        #expect(collected.first == "light")
        #expect(collected.last == "blue")
        try await store.set("dark", for: key)
        let repoBData = try Data(contentsOf: targetB)
        let repoBRoot = try JSONSerialization.jsonObject(with: repoBData) as? [String: Any]
        let repoBApp = repoBRoot?["app"] as? [String: Any]
        let repoBOther = repoBRoot?["other"] as? [String: Any]
        #expect(repoBApp?["appearance"] as? String == "dark")
        #expect(repoBOther?["keep"] as? Bool == true)
        let repoAData = try Data(contentsOf: targetA)
        let repoARoot = try JSONSerialization.jsonObject(with: repoAData) as? [String: Any]
        let repoAApp = repoARoot?["app"] as? [String: Any]
        #expect(repoAApp?["appearance"] as? String == "light")
        let linkAttributes = try FileManager.default.attributesOfItem(atPath: linkURL.path)
        #expect(linkAttributes[.type] as? FileAttributeType == .typeSymbolicLink)
    }

    @Test func observesTargetCreatedForDanglingSymlink() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-settings-symlink-\(UUID().uuidString)", isDirectory: true)
        let repoDir = tempDir.appendingPathComponent("repo", isDirectory: true)
        try FileManager.default.createDirectory(at: repoDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let targetURL = repoDir.appendingPathComponent("cmux.json", isDirectory: false)
        let linkURL = tempDir.appendingPathComponent("cmux.json", isDirectory: false)
        try FileManager.default.createSymbolicLink(at: linkURL, withDestinationURL: targetURL)
        let store = JSONConfigStore(fileURL: linkURL)
        let key = JSONKey<String>(id: "automation.socketPassword", defaultValue: "")
        let payload = #"{"automation":{"socketPassword":"injected"}}"#
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
        let writer = retouchingWriter(payload: payload, fileURL: targetURL)
        let collected = await observedValues(observed)
        writer.cancel()
        #expect(collected.first == "")
        #expect(collected.last == "injected")
    }

    @Test func observesTargetCreatedAfterRetargetToDanglingLink() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-settings-symlink-\(UUID().uuidString)", isDirectory: true)
        let repoA = tempDir.appendingPathComponent("repoA", isDirectory: true)
        let repoC = tempDir.appendingPathComponent("repoC", isDirectory: true)
        try FileManager.default.createDirectory(at: repoA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: repoC, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let targetA = repoA.appendingPathComponent("cmux.json", isDirectory: false)
        let targetC = repoC.appendingPathComponent("cmux.json", isDirectory: false)
        try Data(#"{"app":{"appearance":"light"}}"#.utf8).write(to: targetA)
        let linkURL = tempDir.appendingPathComponent("cmux.json", isDirectory: false)
        try FileManager.default.createSymbolicLink(at: linkURL, withDestinationURL: targetA)
        let store = JSONConfigStore(fileURL: linkURL)
        let key = JSONKey<String>(id: "app.appearance", defaultValue: "")
        let (progress, progressContinuation) = AsyncStream<String>.makeStream()
        let (sawLight, sawLightContinuation) = AsyncStream<Void>.makeStream()
        let (sawDefault, sawDefaultContinuation) = AsyncStream<Void>.makeStream()
        let (sawCreated, sawCreatedContinuation) = AsyncStream<Void>.makeStream()
        let progressGate = Task {
            for await value in progress {
                switch value {
                case "light":
                    sawLightContinuation.yield(); sawLightContinuation.finish()
                case "":
                    sawDefaultContinuation.yield(); sawDefaultContinuation.finish()
                case "created":
                    sawCreatedContinuation.yield(); sawCreatedContinuation.finish()
                    return
                default:
                    break
                }
            }
        }
        let observed = Task<[String], Never> {
            var collected: [String] = []
            for await value in store.values(for: key) {
                collected.append(value)
                progressContinuation.yield(value)
                if value == "created" { break }
            }
            progressContinuation.finish()
            return collected
        }
        await withTimeout(seconds: 8) {
            var it = sawLight.makeAsyncIterator()
            _ = await it.next()
        }
        let writerA = Task {
            while !Task.isCancelled {
                try? FileManager.default.removeItem(at: linkURL)
                try? FileManager.default.createSymbolicLink(at: linkURL, withDestinationURL: targetC)
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
        }
        await withTimeout(seconds: 8) {
            var it = sawDefault.makeAsyncIterator()
            _ = await it.next()
        }
        writerA.cancel()
        _ = await writerA.value
        // Phase B must keep the link parent quiet; targetC writes should be
        // seen only by the secondary watcher refreshed after phase A's retarget.
        let payload = #"{"app":{"appearance":"created"}}"#
        let writerB = retouchingWriter(payload: payload, fileURL: targetC)
        await withTimeout(seconds: 8) {
            var it = sawCreated.makeAsyncIterator()
            _ = await it.next()
        }
        writerB.cancel()
        let collected = await observedValues(observed)
        _ = await progressGate.value
        #expect(collected.first == "light")
        #expect(collected.last == "created")
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
        let fixture = try makeSymlinkFixture()
        defer { try? FileManager.default.removeItem(at: fixture.tempDir) }
        try Data("{}".utf8).write(to: fixture.targetURL)
        try FileManager.default.createSymbolicLink(at: fixture.linkURL, withDestinationURL: fixture.targetURL)
        let store = JSONConfigStore(fileURL: fixture.linkURL)
        let key = JSONKey<String>(id: "app.appearance", defaultValue: "")
        try await store.set("dark", for: key)
        try await assertSymlinkWriteThrough(store: store, linkURL: fixture.linkURL, targetURL: fixture.targetURL, key: key, expected: "dark")
    }

    @Test func writesThroughRelativeSymlinkDestination() async throws {
        let fixture = try makeSymlinkFixture()
        defer { try? FileManager.default.removeItem(at: fixture.tempDir) }
        try Data("{}".utf8).write(to: fixture.targetURL)
        try FileManager.default.createSymbolicLink(atPath: fixture.linkURL.path, withDestinationPath: "repo/cmux.json")
        let store = JSONConfigStore(fileURL: fixture.linkURL)
        let key = JSONKey<String>(id: "app.appearance", defaultValue: "")
        try await store.set("dark", for: key)
        try await assertSymlinkWriteThrough(store: store, linkURL: fixture.linkURL, targetURL: fixture.targetURL, key: key, expected: "dark")
    }

    @Test func writesThroughDanglingSymlinkCreatesTarget() async throws {
        let fixture = try makeSymlinkFixture()
        defer { try? FileManager.default.removeItem(at: fixture.tempDir) }
        try FileManager.default.createSymbolicLink(at: fixture.linkURL, withDestinationURL: fixture.targetURL)
        let store = JSONConfigStore(fileURL: fixture.linkURL)
        let key = JSONKey<String>(id: "app.appearance", defaultValue: "")
        try await store.set("dark", for: key)

        #expect(FileManager.default.fileExists(atPath: fixture.targetURL.path))
        let targetAttributes = try FileManager.default.attributesOfItem(atPath: fixture.targetURL.path)
        #expect(targetAttributes[.type] as? FileAttributeType == .typeRegular)
        try await assertSymlinkWriteThrough(store: store, linkURL: fixture.linkURL, targetURL: fixture.targetURL, key: key, expected: "dark")
    }

    @Test func writesThroughSymlinkChainToFinalTarget() async throws {
        let fixture = try makeSymlinkFixture()
        defer { try? FileManager.default.removeItem(at: fixture.tempDir) }
        try Data("{}".utf8).write(to: fixture.targetURL)
        let midURL = fixture.tempDir.appendingPathComponent("mid.json", isDirectory: false)
        try FileManager.default.createSymbolicLink(at: midURL, withDestinationURL: fixture.targetURL)
        try FileManager.default.createSymbolicLink(at: fixture.linkURL, withDestinationURL: midURL)

        let store = JSONConfigStore(fileURL: fixture.linkURL)
        let key = JSONKey<String>(id: "app.appearance", defaultValue: "")
        try await store.set("dark", for: key)

        let midAttributes = try FileManager.default.attributesOfItem(atPath: midURL.path)
        #expect(midAttributes[.type] as? FileAttributeType == .typeSymbolicLink)
        try await assertSymlinkWriteThrough(store: store, linkURL: fixture.linkURL, targetURL: fixture.targetURL, key: key, expected: "dark")
    }
}

/// Re-applies the same external edit on a loop, bumping the file's modification
/// date each pass. The subscriber can finish registering just after the initial
/// value is yielded, so a single external write could land before the watcher is
/// armed; each re-touch produces a fresh DispatchSource event once it is. The
/// bytes are identical every pass, so this closes the readiness race without
/// weakening what the test asserts.
private func retouchingWriter(payload: String, fileURL: URL) -> Task<Void, Never> {
    Task {
        var bump = Date()
        while !Task.isCancelled {
            try? Data(payload.utf8).write(to: fileURL)
            bump = bump.addingTimeInterval(1)
            try? FileManager.default.setAttributes([.modificationDate: bump], ofItemAtPath: fileURL.path)
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }
}

private func observedValues(_ observed: Task<[String], Never>) async -> [String] {
    await withTimeout(seconds: 8) {
        await withTaskCancellationHandler {
            await observed.value
        } onCancel: {
            observed.cancel()
        }
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
            // Timeout sentinel: cancel the in-flight work so cooperative call
            // sites unwind and surface a partial value; the assertions that
            // follow then fail instead of the run wedging forever.
            group.cancelAll()
        }
        fatalError("timed out without producing a value")
    }
}
