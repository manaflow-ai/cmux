import Foundation
import Testing
@testable import CmuxWorkspaces

/// Minimal stand-in for the app's `AppSessionSnapshot` root: a version plus
/// a window list, mirroring the fields the repository's usability rules read.
private struct SnapshotFixture: SessionSnapshotRepresenting, Equatable {
    struct Window: Codable, Equatable, Sendable {
        var name: String
    }

    var version: Int
    var windows: [Window]

    var hasWindows: Bool { !windows.isEmpty }
}

@Suite("SessionSnapshotRepository")
struct SessionSnapshotRepositoryTests {
    private let schemaVersion = 1

    private func makeTempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-session-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeRepository(
        appSupport: URL,
        bundleIdentifier: String? = "com.cmuxterm.tests",
        repairLoadedSnapshot: @escaping @Sendable (SnapshotFixture) -> (snapshot: SnapshotFixture, didRepair: Bool) = {
            (snapshot: $0, didRepair: false)
        }
    ) -> SessionSnapshotRepository<SnapshotFixture> {
        SessionSnapshotRepository(
            schemaVersion: schemaVersion,
            bundleIdentifier: bundleIdentifier,
            repairLoadedSnapshot: repairLoadedSnapshot,
            appSupportDirectory: appSupport
        )
    }

    private func makeSnapshot(version: Int = 1, windowNames: [String] = ["main"]) -> SnapshotFixture {
        SnapshotFixture(version: version, windows: windowNames.map { .init(name: $0) })
    }

    @Test("save then load round-trips through the default snapshot location")
    func saveLoadRoundTrip() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let repository = makeRepository(appSupport: dir)
        let snapshot = makeSnapshot(windowNames: ["alpha", "beta"])

        #expect(repository.save(snapshot, fileURL: nil))
        #expect(repository.load(fileURL: nil) == snapshot)
    }

    @Test("snapshot file paths derive from the sanitized bundle identifier under cmux/")
    func snapshotFileURLShape() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let repository = makeRepository(appSupport: dir, bundleIdentifier: "com.cmux odd/id")

        let primary = try #require(repository.defaultSnapshotFileURL())
        let backup = try #require(repository.manualRestoreSnapshotFileURL())
        #expect(primary.path == dir.appendingPathComponent("cmux/session-com.cmux_odd_id.json").path)
        #expect(backup.path == dir.appendingPathComponent("cmux/session-com.cmux_odd_id-previous.json").path)
    }

    @Test("nil and blank bundle identifiers fall back to com.cmuxterm.app")
    func bundleIdentifierFallback() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        for identifier in [nil, "  "] as [String?] {
            let repository = makeRepository(appSupport: dir, bundleIdentifier: identifier)
            let primary = try #require(repository.defaultSnapshotFileURL())
            #expect(primary.lastPathComponent == "session-com.cmuxterm.app.json")
        }
    }

    @Test("missing file, corrupt data, version drift, and empty windows are not loadable")
    func loadOutcomeUsabilityRules() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let repository = makeRepository(appSupport: dir)
        let fileURL = try #require(repository.defaultSnapshotFileURL())

        guard case .missing = repository.loadOutcome(fileURL: fileURL) else {
            Issue.record("expected .missing before any write")
            return
        }

        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("not json".utf8).write(to: fileURL)
        guard case .unusable = repository.loadOutcome(fileURL: fileURL) else {
            Issue.record("expected .unusable for corrupt data")
            return
        }

        #expect(repository.save(makeSnapshot(version: schemaVersion + 1), fileURL: fileURL))
        #expect(repository.load(fileURL: fileURL) == nil)

        #expect(repository.save(makeSnapshot(windowNames: []), fileURL: fileURL))
        #expect(repository.load(fileURL: fileURL) == nil)
    }

    @Test("loadOutcome returns repaired snapshots without rewriting the inspected file")
    func loadOutcomeIsReadOnlyForRepairedSnapshots() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let repository = makeRepository(appSupport: dir) { snapshot in
            var repaired = snapshot
            repaired.windows[0].name = "repaired"
            return (snapshot: repaired, didRepair: true)
        }
        let fileURL = try #require(repository.defaultSnapshotFileURL())
        let original = makeSnapshot(windowNames: ["old"])
        let repaired = makeSnapshot(windowNames: ["repaired"])

        #expect(repository.save(original, fileURL: nil))
        let beforeProbe = try Data(contentsOf: fileURL)
        guard case .loaded(let probed) = repository.loadOutcome(fileURL: fileURL) else {
            Issue.record("expected repaired loaded snapshot")
            return
        }
        #expect(probed == repaired)
        #expect(try Data(contentsOf: fileURL) == beforeProbe)

        #expect(repository.load(fileURL: fileURL) == repaired)
        #expect(try JSONDecoder().decode(SnapshotFixture.self, from: Data(contentsOf: fileURL)) == repaired)
    }

    @Test("saving identical content does not rewrite the file")
    func saveSkipsIdenticalContent() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let repository = makeRepository(appSupport: dir)
        let fileURL = try #require(repository.defaultSnapshotFileURL())
        let snapshot = makeSnapshot()

        #expect(repository.save(snapshot, fileURL: nil))
        let firstStamp = try #require(
            try FileManager.default.attributesOfItem(atPath: fileURL.path)[.modificationDate] as? Date
        )
        // Backdate the file so an (incorrect) rewrite would move the stamp forward.
        try FileManager.default.setAttributes(
            [.modificationDate: firstStamp.addingTimeInterval(-3600)],
            ofItemAtPath: fileURL.path
        )
        #expect(repository.save(snapshot, fileURL: nil))
        let secondStamp = try #require(
            try FileManager.default.attributesOfItem(atPath: fileURL.path)[.modificationDate] as? Date
        )
        // A rewrite would stamp "now"; the skipped write leaves the stamp an
        // hour in the past (sub-second filesystem truncation tolerated).
        #expect(abs(secondStamp.timeIntervalSince(firstStamp.addingTimeInterval(-3600))) < 5)
    }

    @Test("removeSnapshot deletes the default snapshot file")
    func removeSnapshot() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let repository = makeRepository(appSupport: dir)
        let fileURL = try #require(repository.defaultSnapshotFileURL())

        #expect(repository.save(makeSnapshot(), fileURL: nil))
        #expect(FileManager.default.fileExists(atPath: fileURL.path))
        repository.removeSnapshot(fileURL: nil)
        #expect(!FileManager.default.fileExists(atPath: fileURL.path))
    }

    @Test("backup sync copies a usable primary into the -previous location")
    func backupSyncCopiesUsablePrimary() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let repository = makeRepository(appSupport: dir)
        let snapshot = makeSnapshot(windowNames: ["restored"])

        #expect(repository.save(snapshot, fileURL: nil))
        repository.syncManualRestoreSnapshotCache()
        #expect(repository.loadReopenSessionSnapshot(fileURL: nil) == snapshot)
    }

    @Test("backup sync removes the backup when the primary is missing")
    func backupSyncRemovesBackupForMissingPrimary() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let repository = makeRepository(appSupport: dir)
        let backupURL = try #require(repository.manualRestoreSnapshotFileURL())

        #expect(repository.save(makeSnapshot(), fileURL: backupURL))
        repository.syncManualRestoreSnapshotCache()
        #expect(!FileManager.default.fileExists(atPath: backupURL.path))
    }

    @Test("backup sync keeps the backup when the primary is unusable")
    func backupSyncKeepsBackupForUnusablePrimary() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let repository = makeRepository(appSupport: dir)
        let primaryURL = try #require(repository.defaultSnapshotFileURL())
        let backupURL = try #require(repository.manualRestoreSnapshotFileURL())
        let backupSnapshot = makeSnapshot(windowNames: ["backup"])

        #expect(repository.save(backupSnapshot, fileURL: backupURL))
        try FileManager.default.createDirectory(
            at: primaryURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("corrupt".utf8).write(to: primaryURL)
        repository.syncManualRestoreSnapshotCache()
        #expect(repository.loadReopenSessionSnapshot(fileURL: nil) == backupSnapshot)
    }

    @Test("startup snapshot prefers the primary and falls back to the backup when unusable")
    func startupSnapshotFallback() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let repository = makeRepository(appSupport: dir)
        let primaryURL = try #require(repository.defaultSnapshotFileURL())
        let backupURL = try #require(repository.manualRestoreSnapshotFileURL())
        let primarySnapshot = makeSnapshot(windowNames: ["primary"])
        let backupSnapshot = makeSnapshot(windowNames: ["backup"])

        #expect(repository.loadStartupSnapshot() == nil)

        #expect(repository.save(primarySnapshot, fileURL: nil))
        #expect(repository.loadStartupSnapshot() == primarySnapshot)

        #expect(repository.save(backupSnapshot, fileURL: backupURL))
        try Data("corrupt".utf8).write(to: primaryURL)
        #expect(repository.loadStartupSnapshot() == backupSnapshot)
    }

    @Test("encoded snapshot bytes use sorted keys (wire-format stability)")
    func wireFormatSortedKeys() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let repository = makeRepository(appSupport: dir)
        let fileURL = try #require(repository.defaultSnapshotFileURL())

        #expect(repository.save(makeSnapshot(windowNames: ["w"]), fileURL: nil))
        let text = try #require(String(data: Data(contentsOf: fileURL), encoding: .utf8))
        #expect(text == #"{"version":1,"windows":[{"name":"w"}]}"#)
    }
}
