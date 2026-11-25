import Foundation
@testable import CmuxNextUpdater
import Testing

/// The install preflight looks for Sparkle's staged update in both homes' caches: the app's (`HOME`)
/// and the account's, where launchd's installer stages it. With a `HOME` override (the release
/// rollback drill's walk home) the app's folder is the empty one it made itself, and the preflight
/// refused a staged update as missing (drill 11, hq run 45422799252; goal release-rollback-drilled).
@Suite struct UpdatePreflightTwoHomesTests {
    private static func scratch() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "preflight-two-homes-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private static func preflight(root: URL, folders: [URL]) throws -> UpdateInstallPreflight {
        let bundle = root.appending(path: "Apps/cmux.app", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        return UpdateInstallPreflight(bundle: bundle, updateBytes: nil, stagedInstallations: folders)
    }

    @Test func anUpdateStagedInTheAccountHomeIsNotMissing() throws {
        let root = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let own = root.appending(path: "walk/Library/Caches/id/org.sparkle-project.Sparkle/Installation", directoryHint: .isDirectory)
        let account = root.appending(path: "home/Library/Caches/id/org.sparkle-project.Sparkle/Installation", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: own, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: account.appending(path: "abc/def", directoryHint: .isDirectory), withIntermediateDirectories: true)
        let check = try Self.preflight(root: root, folders: [own, account])
        #expect(check.failure() == nil)
        #expect(check.knowsStagedLayout())
    }

    @Test func bothFoldersEmptyIsMissing() throws {
        let root = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let own = root.appending(path: "walk/Installation", directoryHint: .isDirectory)
        let account = root.appending(path: "home/Installation", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: own, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: account, withIntermediateDirectories: true)
        try Data().write(to: account.appending(path: ".DS_Store"))
        #expect(try Self.preflight(root: root, folders: [own, account]).failure() == .updateMissing)
    }

    @Test func noSparkleFolderAnywhereLetsTheClickThrough() throws {
        let root = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let check = try Self.preflight(root: root, folders: [root.appending(path: "a/S/Installation"), root.appending(path: "b/S/Installation")])
        #expect(check.failure() == nil)
        #expect(!check.knowsStagedLayout())
    }

    @Test func theAccountFolderJoinsOnlyWhenHomesDiffer() {
        let own = UpdateInstallPreflight.stagedInstallation(bundleIdentifier: "com.example.id")
        #expect(UpdateInstallPreflight.stagedInstallations(bundleIdentifier: "com.example.id", accountHome: nil) == [own])
        let ownHome = own.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        #expect(UpdateInstallPreflight.stagedInstallations(bundleIdentifier: "com.example.id", accountHome: ownHome) == [own])
        let other = URL(filePath: "/Users/someone-else", directoryHint: .isDirectory)
        let both = UpdateInstallPreflight.stagedInstallations(bundleIdentifier: "com.example.id", accountHome: other)
        #expect(both.count == 2)
        #expect(both[1].path.hasPrefix("/Users/someone-else/Library/Caches/com.example.id/org.sparkle-project.Sparkle/Installation"))
    }

    @Test func thePrewarmKeepsEveryFolderAndTheAppsOwnFirst() throws {
        let prewarm = StagedUpdatePrewarm(installations: [URL(filePath: "/tmp/a"), URL(filePath: "/tmp/b")],
                                          bundleIdentifier: "id", build: "1")
        #expect(prewarm.installation == URL(filePath: "/tmp/a"))
        #expect(prewarm.installations.count == 2)
    }
}
