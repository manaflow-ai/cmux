@testable import CmuxNextApp
import Foundation
import Testing

@Suite struct LegacyHistoryFileTests {
    @Test func aProfileSymlinkCannotRedirectHistoryCleanup() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let support = root.appending(path: "support", directoryHint: .isDirectory)
        let profiles = support.appending(path: "BrowserProfiles", directoryHint: .isDirectory)
        let external = root.appending(path: "external", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: profiles, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: profiles.appending(path: "default"),
            withDestinationURL: external
        )
        let history = external.appending(path: "History.sqlite")
        try Data("outside".utf8).write(to: history)

        let redirected = profiles.appending(path: "default/History.sqlite")
        #expect(LegacyHistoryFile(url: redirected, supportDirectory: support) == nil)
        #expect(FileManager.default.fileExists(atPath: history.path))
    }

    @Test func aFileReplacedDuringImportIsNotDeleted() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let support = root.appending(path: "support", directoryHint: .isDirectory)
        let profile = support.appending(path: "BrowserProfiles/default", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
        let history = profile.appending(path: "History.sqlite")
        try Data("before".utf8).write(to: history)
        let tracked = try #require(LegacyHistoryFile(url: history, supportDirectory: support))
        try FileManager.default.removeItem(at: history)
        try Data("after".utf8).write(to: history)

        tracked.removeIfUnchanged()
        #expect(FileManager.default.fileExists(atPath: history.path))
    }

    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "cmux-legacy-history-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}
