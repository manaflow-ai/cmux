import Foundation
import Testing
@testable import CmuxSettings

@Suite("Browser web-extension paths")
struct BrowserWebExtensionPathTests {
    @Test
    func realAndSymbolicLinkPathsHaveTheSameIdentity() throws {
        let fileManager = FileManager.default
        let temporaryDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-web-extension-paths-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: temporaryDirectory) }

        let realDirectory = temporaryDirectory.appendingPathComponent("RealExtension", isDirectory: true)
        let linkedDirectory = temporaryDirectory.appendingPathComponent("LinkedExtension", isDirectory: true)
        try fileManager.createDirectory(at: realDirectory, withIntermediateDirectories: true)
        try fileManager.createSymbolicLink(at: linkedDirectory, withDestinationURL: realDirectory)

        #expect(
            linkedDirectory.browserWebExtensionStandardizedPath
                == realDirectory.browserWebExtensionStandardizedPath
        )
    }

    @Test
    func realAndSymbolicLinkSafariBundlesHaveTheSameResourceRootIdentity() throws {
        let fileManager = FileManager.default
        let temporaryDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-safari-extension-paths-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: temporaryDirectory) }

        let realBundle = temporaryDirectory.appendingPathComponent("RealExtension.appex", isDirectory: true)
        let linkedBundle = temporaryDirectory.appendingPathComponent("LinkedExtension.appex", isDirectory: true)
        try fileManager.createDirectory(
            at: realBundle.appendingPathComponent("Contents/Resources", isDirectory: true),
            withIntermediateDirectories: true
        )
        try fileManager.createSymbolicLink(at: linkedBundle, withDestinationURL: realBundle)

        #expect(
            linkedBundle.browserWebExtensionSafariResourceRootPath
                == realBundle.browserWebExtensionSafariResourceRootPath
        )
    }
}
