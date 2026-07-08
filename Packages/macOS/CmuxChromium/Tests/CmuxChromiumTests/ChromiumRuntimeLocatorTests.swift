import Foundation
import Testing
@testable import CmuxChromium

struct ChromiumRuntimeLocatorTests {
    private func makeRuntimeDirectory(in root: URL, named name: String, withManifest: Bool = true) throws -> URL {
        let fileManager = FileManager.default
        let directory = root.appendingPathComponent(name, isDirectory: true)
        let shellDir = directory.appendingPathComponent("Content Shell.app/Contents/MacOS", isDirectory: true)
        try fileManager.createDirectory(at: shellDir, withIntermediateDirectories: true)
        fileManager.createFile(atPath: shellDir.appendingPathComponent("Content Shell").path, contents: Data())
        fileManager.createFile(
            atPath: directory.appendingPathComponent(ChromiumRuntimeBundle.libraryFileName).path,
            contents: Data()
        )
        if withManifest {
            let manifest = """
            {"chromiumSourceCommit": "\(name)"}
            """
            try Data(manifest.utf8).write(to: directory.appendingPathComponent(ChromiumRuntimeBundle.manifestFileName))
        }
        return directory
    }

    private func makeTempRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CmuxChromiumTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test func environmentOverrideWins() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let overridden = try makeRuntimeDirectory(in: root, named: "override")
        _ = try makeRuntimeDirectory(in: root.appendingPathComponent("install"), named: "other")
        let locator = ChromiumRuntimeLocator(
            environment: [ChromiumRuntimeLocator.environmentOverrideKey: overridden.path],
            installRoot: root.appendingPathComponent("install")
        )
        let bundle = try locator.locate()
        #expect(bundle.rootDirectory.standardizedFileURL == overridden.standardizedFileURL)
        #expect(bundle.manifest?.chromiumSourceCommit == "override")
    }

    @Test func invalidOverrideThrowsValidationError() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let empty = root.appendingPathComponent("empty", isDirectory: true)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        let locator = ChromiumRuntimeLocator(
            environment: [ChromiumRuntimeLocator.environmentOverrideKey: empty.path],
            installRoot: root
        )
        #expect(throws: ChromiumRuntimeError.self) {
            _ = try locator.locate()
        }
    }

    @Test func picksNewestValidInstall() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let older = try makeRuntimeDirectory(in: root, named: "older")
        let newer = try makeRuntimeDirectory(in: root, named: "newer")
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: -3600)],
            ofItemAtPath: older.path
        )
        try FileManager.default.setAttributes(
            [.modificationDate: Date()],
            ofItemAtPath: newer.path
        )
        let locator = ChromiumRuntimeLocator(environment: [:], installRoot: root)
        let bundle = try locator.locate()
        #expect(bundle.rootDirectory.lastPathComponent == "newer")
    }

    @Test func skipsInvalidDirectories() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let broken = root.appendingPathComponent("broken", isDirectory: true)
        try FileManager.default.createDirectory(at: broken, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: broken.path)
        let valid = try makeRuntimeDirectory(in: root, named: "valid")
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: -3600)],
            ofItemAtPath: valid.path
        )
        let locator = ChromiumRuntimeLocator(environment: [:], installRoot: root)
        let bundle = try locator.locate()
        #expect(bundle.rootDirectory.lastPathComponent == "valid")
    }

    @Test func throwsWhenNothingInstalled() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let locator = ChromiumRuntimeLocator(environment: [:], installRoot: root)
        #expect(throws: ChromiumRuntimeError.self) {
            _ = try locator.locate()
        }
    }

    @Test func missingLibraryIsReported() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = try makeRuntimeDirectory(in: root, named: "runtime")
        try FileManager.default.removeItem(
            at: directory.appendingPathComponent(ChromiumRuntimeBundle.libraryFileName)
        )
        let locator = ChromiumRuntimeLocator(environment: [:], installRoot: root)
        do {
            _ = try locator.bundle(at: directory)
            Issue.record("expected invalidRuntimeDirectory")
        } catch let ChromiumRuntimeError.invalidRuntimeDirectory(_, missing) {
            #expect(missing == ChromiumRuntimeBundle.libraryFileName)
        }
    }
}
