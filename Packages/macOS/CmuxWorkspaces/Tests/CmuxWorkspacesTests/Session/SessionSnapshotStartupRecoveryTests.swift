import Foundation
import Testing
@testable import CmuxWorkspaces

private struct RecoverySnapshotFixture: SessionSnapshotRepresenting, Equatable {
    var version: Int
    var workspaces: [String]

    var hasWindows: Bool { !workspaces.isEmpty }
    var richness: SessionSnapshotRichness {
        SessionSnapshotRichness(workspaces: workspaces.count, panels: workspaces.count)
    }
}

/// Startup must never come up empty while restorable session data is still
/// on disk: an unreadable primary and backup fall back to the rotated
/// history, and the unreadable bytes are kept aside instead of being
/// replaced by the next autosave.
@Suite("Session snapshot startup recovery")
struct SessionSnapshotStartupRecoveryTests {
    private let schemaVersion = 1

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-session-recovery-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func makeRepository(root: URL) -> SessionSnapshotRepository<RecoverySnapshotFixture> {
        SessionSnapshotRepository(
            schemaVersion: schemaVersion,
            bundleIdentifier: "com.cmuxterm.app.nightly",
            appSupportDirectory: root
        )
    }

    /// Archives `snapshot` into history the way a launch does.
    private func archive(
        _ snapshot: RecoverySnapshotFixture,
        in repository: SessionSnapshotRepository<RecoverySnapshotFixture>,
        root: URL,
        at seconds: TimeInterval
    ) throws {
        let staging = root.appendingPathComponent("staging-\(UUID().uuidString).json")
        #expect(repository.save(snapshot, fileURL: staging))
        try #require(repository.archiveSnapshotToHistory(
            fileURL: staging,
            richness: snapshot.richness,
            archivedAt: Date(timeIntervalSince1970: seconds)
        ) != nil)
        try FileManager.default.removeItem(at: staging)
    }

    private func writeRaw(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(text.utf8).write(to: url)
    }

    @Test("an unreadable primary and backup restore the newest usable history snapshot")
    func unusablePrimaryAndBackupRecoverFromHistory() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = makeRepository(root: root)
        let older = RecoverySnapshotFixture(version: 1, workspaces: ["older"])
        let newest = RecoverySnapshotFixture(version: 1, workspaces: ["a", "b", "c"])
        try archive(older, in: repository, root: root, at: 1_000)
        try archive(newest, in: repository, root: root, at: 2_000)
        // A newer, unreadable archive must be skipped, not end the search.
        let historyDirectory = try #require(repository.historyDirectoryURL())
        try writeRaw(
            "{\"version\":1,\"workspaces\":42}",
            to: historyDirectory.appendingPathComponent("session-com.cmuxterm.app.nightly-3000000-w9-p9.json")
        )
        try writeRaw("{\"version\":1,\"workspaces\":\"not-a-list\"}", to: try #require(repository.defaultSnapshotFileURL()))
        try writeRaw("corrupt", to: try #require(repository.manualRestoreSnapshotFileURL()))

        #expect(repository.loadStartupSnapshot() == newest)
    }

    @Test("the startup sync keeps an unreadable primary aside on its own")
    func syncPreservesUnusablePrimary() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = makeRepository(root: root)
        let primaryURL = try #require(repository.defaultSnapshotFileURL())
        let unreadable = "{\"version\":1,\"workspaces\":7}"
        try writeRaw(unreadable, to: primaryURL)

        repository.syncManualRestoreSnapshotCache()
        #expect(repository.save(RecoverySnapshotFixture(version: 1, workspaces: ["fresh"]), fileURL: nil))

        let survivors = try FileManager.default
            .contentsOfDirectory(at: primaryURL.deletingLastPathComponent(), includingPropertiesForKeys: nil)
            .filter { (try? String(contentsOf: $0, encoding: .utf8)) == unreadable }
        #expect(survivors.count == 1, "the unreadable snapshot must stay on disk")
    }
}
