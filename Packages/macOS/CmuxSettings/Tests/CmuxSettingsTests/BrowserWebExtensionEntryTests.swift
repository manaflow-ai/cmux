import Foundation
import Testing
@testable import CmuxSettings

@Suite("Browser web extension resource identity")
struct BrowserWebExtensionEntryTests {
    @Test
    func unpackedDirectorySymlinkAliasSharesResourceIdentity() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-web-extension-\(UUID().uuidString)", isDirectory: true)
        let realDirectory = root.appendingPathComponent("real", isDirectory: true)
        let aliasDirectory = root.appendingPathComponent("alias", isDirectory: true)
        try FileManager.default.createDirectory(at: realDirectory, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: aliasDirectory, withDestinationURL: realDirectory)
        defer { try? FileManager.default.removeItem(at: root) }

        let realIdentity = BrowserWebExtensionEntry.standardizedResourceRootPath(
            for: .unpackedDirectory,
            path: realDirectory.path
        )
        let aliasIdentity = BrowserWebExtensionEntry.standardizedResourceRootPath(
            for: .unpackedDirectory,
            path: aliasDirectory.path
        )

        #expect(realIdentity == realDirectory.standardizedFileURL.path)
        #expect(aliasIdentity == realIdentity)
    }

    @Test
    func safariAppExtensionSymlinkAliasSharesResourcesIdentity() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-safari-extension-\(UUID().uuidString)", isDirectory: true)
        let realAppExtension = root.appendingPathComponent("Real.appex", isDirectory: true)
        let resources = realAppExtension.appendingPathComponent("Contents/Resources", isDirectory: true)
        let aliasAppExtension = root.appendingPathComponent("Alias.appex", isDirectory: true)
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: aliasAppExtension, withDestinationURL: realAppExtension)
        defer { try? FileManager.default.removeItem(at: root) }

        let realIdentity = BrowserWebExtensionEntry.standardizedResourceRootPath(
            for: .safariAppExtension,
            path: realAppExtension.path
        )
        let aliasIdentity = BrowserWebExtensionEntry.standardizedResourceRootPath(
            for: .safariAppExtension,
            path: aliasAppExtension.path
        )

        #expect(realIdentity == resources.standardizedFileURL.path)
        #expect(aliasIdentity == realIdentity)
    }
}
