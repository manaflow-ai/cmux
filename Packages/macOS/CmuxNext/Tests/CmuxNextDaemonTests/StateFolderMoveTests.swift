import CmuxNextCompat
import Foundation
import Testing
@testable import CmuxNextDaemon

/// A build's folder leaves classic cmux's `Application Support/cmux` once, with everything in it
/// (cmuxterm-hq goals/next-store-out-of-classic.md; air-blue setup flows 2026-11-08, issue 5).
struct StateFolderMoveTests {
    private static func support() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "state-move-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private static let nightly = BuildIdentity(bundleID: "com.cmuxterm.app.nightly", bundledTag: nil)

    @Test func nightlysFolderMovesOutOfClassicsWithALinkBack() throws {
        let support = try Self.support()
        defer { try? FileManager.default.removeItem(at: support) }
        let old = support.appending(path: "cmux/tags/nightly", directoryHint: .isDirectory)
        let registry = old.appending(path: "tui/cmux-app-nightly-1/workspace-registry.sqlite3")
        try FileManager.default.createDirectory(at: registry.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("workspaces".utf8).write(to: registry)
        try Data("{}".utf8).write(to: old.appending(path: "legacy-session-adopted"))
        let classicSession = support.appending(path: "cmux/session-com.cmuxterm.app.json")
        try Data("classic".utf8).write(to: classicSession)

        let move = StateFolderMove(applicationSupport: support)
        #expect(move.run(build: Self.nightly) == .moved)
        let new = support.appending(path: "cmux-next/tags/nightly", directoryHint: .isDirectory)
        #expect(DaemonLauncher.appNames(build: Self.nightly, applicationSupport: support).stateDirectory?.path
            == new.appending(path: "tui").path)
        #expect(try String(contentsOf: new.appending(path: "tui/cmux-app-nightly-1/workspace-registry.sqlite3"), encoding: .utf8) == "workspaces")
        #expect(FileManager.default.fileExists(atPath: new.appending(path: "legacy-session-adopted").path))
        // An older build (a rollback) still finds its state through the old path.
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: old.path) == new.path)
        #expect(try String(contentsOf: registry, encoding: .utf8) == "workspaces")
        // Classic's own files stay where classic keeps them.
        #expect(try String(contentsOf: classicSession, encoding: .utf8) == "classic")
        // Once: the link left behind is not moved again.
        #expect(move.run(build: Self.nightly) == .nothing)
    }

    @Test func aFolderAlreadyAtTheNewPlaceIsNeverReplaced() throws {
        let support = try Self.support()
        defer { try? FileManager.default.removeItem(at: support) }
        let old = support.appending(path: "cmux/tags/nightly/tui", directoryHint: .isDirectory)
        let new = support.appending(path: "cmux-next/tags/nightly/tui", directoryHint: .isDirectory)
        for folder in [old, new] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        try Data("old".utf8).write(to: old.appending(path: "a"))
        try Data("new".utf8).write(to: new.appending(path: "b"))

        guard case .kept = StateFolderMove(applicationSupport: support).run(build: Self.nightly) else {
            Issue.record("a move over a used folder")
            return
        }
        #expect(try String(contentsOf: old.appending(path: "a"), encoding: .utf8) == "old")
        #expect(try String(contentsOf: new.appending(path: "b"), encoding: .utf8) == "new")
    }

    @Test func nothingToMoveForAFreshMacOrRelease() throws {
        let support = try Self.support()
        defer { try? FileManager.default.removeItem(at: support) }
        #expect(StateFolderMove(applicationSupport: support).run(build: Self.nightly) == .nothing)
        let release = BuildIdentity(bundleID: "com.cmuxterm.app", bundledTag: nil)
        #expect(StateFolderMove(applicationSupport: support).folders(build: release) == nil)
        #expect(!FileManager.default.fileExists(atPath: support.appending(path: "cmux").path))
    }

    @Test func aPerKeyBuildMovesItsBuildsFolder() throws {
        let support = try Self.support()
        defer { try? FileManager.default.removeItem(at: support) }
        let dev = BuildIdentity(bundleID: "com.cmuxterm.app.debug", bundledTag: nil)
        let folders = try #require(StateFolderMove(applicationSupport: support).folders(build: dev))
        #expect(folders.old.path.hasSuffix("/cmux/builds/\(dev.key)"))
        #expect(folders.new.path.hasSuffix("/cmux-next/builds/\(dev.key)"))
    }
}
