import Foundation
import Testing
@testable import CmuxSettings

@Suite("JSONConfigStore symlink handling")
struct JSONConfigStoreSymlinkTests {
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

    @Test func writeAfterRetargetWithoutSubscriberPreservesNewTargetContents() async throws {
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
        #expect(await store.value(for: key) == "light")

        try FileManager.default.removeItem(at: linkURL)
        try FileManager.default.createSymbolicLink(at: linkURL, withDestinationURL: targetB)
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
        #expect(await store.value(for: key) == "dark")
    }

    @Test func readAfterRetargetWithoutSubscriberReflectsNewTarget() async throws {
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
        #expect(await store.value(for: key) == "light")

        try FileManager.default.removeItem(at: linkURL)
        try FileManager.default.createSymbolicLink(at: linkURL, withDestinationURL: targetB)
        #expect(await store.value(for: key) == "blue")
    }
}
