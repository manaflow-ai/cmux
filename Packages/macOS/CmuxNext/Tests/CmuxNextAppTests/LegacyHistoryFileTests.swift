@testable import CmuxNextApp
import Foundation
import Testing
import CmuxNextHistory

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

    @Test func anEncodedDotDotCannotLeaveTheSupportDirectory() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let support = root.appending(path: "support", directoryHint: .isDirectory)
        let outside = root.appending(path: "escape", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let history = outside.appending(path: "History.sqlite")
        try Data("outside".utf8).write(to: history)

        for dots in ["%2E%2E", ".%2e"] {
            let crafted = try #require(URL(string: support.absoluteString + "\(dots)/escape/History.sqlite"))
            #expect(LegacyHistoryFile(url: crafted, supportDirectory: support) == nil, "\(dots)")
        }
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

    @Test func aSymlinkAboveTheSupportDirectoryCannotRedirectCleanup() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let real = root.appending(path: "real", directoryHint: .isDirectory)
        let support = real.appending(path: "support", directoryHint: .isDirectory)
        let profile = support.appending(path: "BrowserProfiles/default", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
        let history = profile.appending(path: "History.sqlite")
        try Data("outside".utf8).write(to: history)
        let link = root.appending(path: "linked-root", directoryHint: .isDirectory)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)

        let linkedSupport = link.appending(path: "support", directoryHint: .isDirectory)
        let linkedHistory = linkedSupport.appending(path: "BrowserProfiles/default/History.sqlite")
        #expect(LegacyHistoryFile(url: linkedHistory, supportDirectory: linkedSupport) == nil)
        #expect(FileManager.default.fileExists(atPath: history.path))
    }

    @Test func aProfileMovedBehindASymlinkDuringImportIsNotDeleted() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let support = root.appending(path: "support", directoryHint: .isDirectory)
        let profiles = support.appending(path: "BrowserProfiles", directoryHint: .isDirectory)
        let profile = profiles.appending(path: "default", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
        let history = profile.appending(path: "History.sqlite")
        try Data("before".utf8).write(to: history)
        let tracked = try #require(LegacyHistoryFile(url: history, supportDirectory: support))

        let moved = root.appending(path: "moved-profile", directoryHint: .isDirectory)
        try FileManager.default.moveItem(at: profile, to: moved)
        try FileManager.default.createSymbolicLink(at: profile, withDestinationURL: moved)

        tracked.removeIfUnchanged()
        #expect(FileManager.default.fileExists(atPath: moved.appending(path: "History.sqlite").path))
    }

    @Test func aChangedWALKeepsTheWholeCapturedGeneration() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let support = root.appending(path: "support", directoryHint: .isDirectory)
        let profile = support.appending(path: "BrowserProfiles/default", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
        let history = profile.appending(path: "History.sqlite")
        let wal = URL(fileURLWithPath: history.path + "-wal")
        let shm = URL(fileURLWithPath: history.path + "-shm")
        try Data("database".utf8).write(to: history)
        try Data("wal-before".utf8).write(to: wal)
        let trackedHistory = try #require(LegacyHistoryFile(url: history, supportDirectory: support))
        let trackedWAL = try #require(LegacyHistoryFile(url: wal, supportDirectory: support))
        try Data("wal-after".utf8).write(to: wal)

        #expect(!LegacyHistoryFile.removeGenerationIfUnchanged(
            [trackedWAL, trackedHistory],
            missing: [shm]
        ))
        #expect(FileManager.default.fileExists(atPath: history.path))
        #expect(FileManager.default.fileExists(atPath: wal.path))
    }

    @Test func anUnchangedSQLiteGenerationIsRemovedTogether() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let support = root.appending(path: "support", directoryHint: .isDirectory)
        let profile = support.appending(path: "BrowserProfiles/default", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
        let history = profile.appending(path: "History.sqlite")
        let wal = URL(fileURLWithPath: history.path + "-wal")
        let shm = URL(fileURLWithPath: history.path + "-shm")
        for file in [history, wal, shm] { try Data(file.lastPathComponent.utf8).write(to: file) }
        let tracked = try [shm, wal, history].map {
            try #require(LegacyHistoryFile(url: $0, supportDirectory: support))
        }

        #expect(LegacyHistoryFile.removeGenerationIfUnchanged(tracked, missing: []))
        for file in [history, wal, shm] { #expect(!FileManager.default.fileExists(atPath: file.path)) }
    }

    /// A root with no symbolic link anywhere above it, as cleanup requires. The temporary
    /// folder is /var/folders/… and /var links to /private/var; `resolvingSymlinksInPath()`
    /// drops a leading /private again, so the real path comes from realpath(3).
    private func temporaryRoot() throws -> URL {
        let temporary = try #require(realpath(FileManager.default.temporaryDirectory.path, nil))
        defer { free(temporary) }
        let root = URL(fileURLWithPath: String(cString: temporary), isDirectory: true).appending(
            path: "cmux-legacy-history-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}
