import Foundation
import Testing

@testable import CEFKit

@Suite("CEFExtensionStager")
struct CEFExtensionStagerTests {
    @Test func stagesOnlyManifestDirectoriesIntoWritableRoot() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? fm.removeItem(at: root) }

        let good = root.appendingPathComponent("src/good", isDirectory: true)
        let bad = root.appendingPathComponent("src/bad", isDirectory: true)
        try fm.createDirectory(at: good, withIntermediateDirectories: true)
        try fm.createDirectory(at: bad, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: good.appendingPathComponent("manifest.json"))

        let cacheRoot = root.appendingPathComponent("cache", isDirectory: true)
        let staged = CEFExtensionStager.stage([good, bad], rootCachePath: cacheRoot)

        #expect(staged.count == 1)
        #expect(staged.first?.lastPathComponent == "good")
        let stagedManifest = staged.first?.appendingPathComponent("manifest.json").path
        #expect(stagedManifest.map { fm.fileExists(atPath: $0) } == true)
        // Staged copies live under the root cache path, not the source.
        #expect(staged.first?.path.hasPrefix(cacheRoot.path) == true)
    }

    @Test func restagingReplacesAnExistingCopy() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? fm.removeItem(at: root) }

        let source = root.appendingPathComponent("src/ext", isDirectory: true)
        try fm.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: source.appendingPathComponent("manifest.json"))
        let cacheRoot = root.appendingPathComponent("cache", isDirectory: true)

        _ = CEFExtensionStager.stage([source], rootCachePath: cacheRoot)
        try Data(#"{"v":2}"#.utf8).write(to: source.appendingPathComponent("manifest.json"))
        let staged = CEFExtensionStager.stage([source], rootCachePath: cacheRoot)

        #expect(staged.count == 1)
        let contents = try #require(staged.first.map { try Data(contentsOf: $0.appendingPathComponent("manifest.json")) })
        #expect(contents == Data(#"{"v":2}"#.utf8), "restaging must copy the current source content")
    }
}
