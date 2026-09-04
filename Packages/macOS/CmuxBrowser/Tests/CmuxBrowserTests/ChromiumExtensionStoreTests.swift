import Foundation
import Testing
@testable import CmuxBrowser

@Suite("Chromium unpacked extension storage")
struct ChromiumExtensionStoreTests {
    @Test("MV3 snapshots preserve identity across updates and isolate profiles")
    func snapshots() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source")
        try Self.fixture(source)
        let store = Self.store(root)
        let profile = UUID()
        let first = try #require(try await store.prepare(directories: [source.path], profileID: profile).first)
        let same = try await store.prepare(directories: [source.path], profileID: profile)
        #expect(same == [first])
        let other = try #require(try await store.prepare(directories: [source.path], profileID: UUID()).first)
        #expect(other != first)
        let firstKey = try Self.key(first)
        #expect(try firstKey != Self.key(other))
        try Data("console.log('updated')".utf8).write(to: source.appendingPathComponent("content.js"))
        let updated = try #require(try await store.prepare(directories: [source.path], profileID: profile).first)
        #expect(updated != first)
        #expect(try Self.key(updated) == firstKey)
        #expect(FileManager.default.fileExists(atPath: first.path))
        #expect(try String(contentsOf: first.appendingPathComponent("content.js"), encoding: .utf8) == "console.log('initial')")
    }

    @Test("Invalid manifests, paths, symlinks and missing workers are rejected", arguments: ["relative", "missing", "manifest", "worker", "symlink", "comma"])
    func invalid(reason: String) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent(reason == "comma" ? "bad,path" : "source")
        try Self.fixture(source)
        switch reason {
        case "manifest": try Data("{}".utf8).write(to: source.appendingPathComponent("manifest.json"))
        case "worker": try FileManager.default.removeItem(at: source.appendingPathComponent("worker.js"))
        case "symlink": try FileManager.default.createSymbolicLink(at: source.appendingPathComponent("escape"), withDestinationURL: root)
        default: break
        }
        let path = reason == "relative" ? "relative/path" : reason == "missing" ? root.appendingPathComponent("missing").path : source.path
        await #expect(throws: ChromiumExtensionError.self) {
            _ = try await Self.store(root).prepare(directories: [path], profileID: UUID())
        }
    }

    private static func store(_ root: URL) -> ChromiumExtensionStore {
        ChromiumExtensionStore(storage: ChromiumOwnedStorage(
            fileManager: .default, applicationSupportURLProvider: { root },
            bundleIdentifierProvider: { "com.cmux.extension-test" }
        ))
    }

    private static func fixture(_ source: URL) throws {
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let manifest = #"{"manifest_version":3,"name":"fixture","version":"1.0","background":{"service_worker":"worker.js"},"content_scripts":[{"matches":["<all_urls>"],"js":["content.js"]}]}"#
        for (name, value) in [("manifest.json", manifest), ("content.js", "console.log('initial')"), ("worker.js", "console.log('worker')")] {
            try Data(value.utf8).write(to: source.appendingPathComponent(name))
        }
    }

    private static func key(_ root: URL) throws -> String? {
        (try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("manifest.json"))) as? [String: Any])?["key"] as? String
    }
}
