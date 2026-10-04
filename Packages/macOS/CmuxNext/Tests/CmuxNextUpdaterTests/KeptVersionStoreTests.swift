import Foundation
import Testing
@testable import CmuxNextUpdater

/// Rollback keeps the running bundle before each install and prunes to
/// `updates.keepPreviousVersions`.
@Suite struct KeptVersionStoreTests {
    private func scratch() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "kept-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func bundle(in dir: URL, build: String, schemas: [String: Int]?) throws -> URL {
        let app = dir.appending(path: "src-\(build)/cmux NIGHTLY.app")
        let contents = app.appending(path: "Contents")
        try FileManager.default.createDirectory(at: contents.appending(path: "MacOS"), withIntermediateDirectories: true)
        var info: [String: Any] = ["CFBundleVersion": build, "CFBundleShortVersionString": "1.0.0-nightly.\(build)"]
        if let schemas { info["CmuxStoreSchemas"] = schemas }
        let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try data.write(to: contents.appending(path: "Info.plist"))
        try Data("binary".utf8).write(to: contents.appending(path: "MacOS/cmux"))
        return app
    }

    @Test func keepsTheBundleAndReadsItsSchemas() throws {
        let dir = try scratch()
        let store = KeptVersionStore(root: dir.appending(path: "versions"), teamID: { _ in "TEAM" })
        try store.keep(bundle: try bundle(in: dir, build: "10", schemas: ["workspace_registry": 15]), build: "10", limit: 1)
        let kept = store.list()
        #expect(kept.map(\.build) == ["10"])
        #expect(kept.first?.storeSchemas == ["workspace_registry": 15])
        #expect(kept.first?.shortVersion == "1.0.0-nightly.10")
        #expect(kept.first?.teamID == "TEAM")
        #expect(FileManager.default.fileExists(atPath: kept.first!.bundle.appending(path: "Contents/MacOS/cmux").path))
    }

    @Test func prunesToTheNewestLimit() throws {
        let dir = try scratch()
        let store = KeptVersionStore(root: dir.appending(path: "versions"), teamID: { _ in nil })
        for build in ["9", "10", "11"] {
            try store.keep(bundle: try bundle(in: dir, build: build, schemas: nil), build: build, limit: 2)
        }
        #expect(store.list().map(\.build) == ["11", "10"])
        try store.keep(bundle: try bundle(in: dir, build: "12", schemas: nil), build: "12", limit: 0)
        #expect(store.list().isEmpty)
    }

    @Test func keepingTheSameBuildTwiceReplacesIt() throws {
        let dir = try scratch()
        let store = KeptVersionStore(root: dir.appending(path: "versions"), teamID: { _ in nil })
        try store.keep(bundle: try bundle(in: dir, build: "10", schemas: nil), build: "10", limit: 3)
        try store.keep(bundle: try bundle(in: dir, build: "10", schemas: ["a": 1]), build: "10", limit: 3)
        #expect(store.list().map(\.build) == ["10"])
        #expect(store.list().first?.storeSchemas == ["a": 1])
    }
}
