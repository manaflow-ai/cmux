import Foundation
import Testing
@testable import CmuxWorkspaces

/// Version plus window list, the fields the repository's usability rules read.
private struct TransferSnapshotFixture: SessionSnapshotRepresenting, Equatable {
    struct Window: Codable, Equatable, Sendable {
        var name: String
    }

    var version: Int
    var windows: [Window]

    var hasWindows: Bool { !windows.isEmpty }
}

@Suite("Session snapshot transfer between installs")
struct SessionSnapshotTransferTests {
    private let schemaVersion = 1

    private func makeTempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-session-transfer-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeRepository(
        appSupport: URL,
        bundleIdentifier: String
    ) -> SessionSnapshotRepository<TransferSnapshotFixture> {
        SessionSnapshotRepository(
            schemaVersion: schemaVersion,
            bundleIdentifier: bundleIdentifier,
            appSupportDirectory: appSupport
        )
    }

    private func snapshot(_ names: String...) -> TransferSnapshotFixture {
        TransferSnapshotFixture(version: schemaVersion, windows: names.map { .init(name: $0) })
    }

    private func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(text.utf8).write(to: url)
    }

    // MARK: - Channel and path resolution

    @Test(
        "channel names map to their bundle identifiers",
        arguments: [
            ("stable", "com.cmuxterm.app"),
            ("Release", "com.cmuxterm.app"),
            ("nightly", "com.cmuxterm.app.nightly"),
            ("RC", "com.cmuxterm.app.rc"),
            ("staging", "com.cmuxterm.app.staging"),
            ("debug", "com.cmuxterm.app.debug"),
            ("debug:my-tag", "com.cmuxterm.app.debug.my-tag"),
            ("dev:My-Tag", "com.cmuxterm.app.debug.My-Tag"),
            ("com.cmuxterm.app.nightly.isolated", "com.cmuxterm.app.nightly.isolated"),
        ]
    )
    func channelBundleIdentifiers(name: String, expected: String) {
        #expect(SessionSnapshotFileLocation.bundleIdentifier(forChannel: name) == expected)
    }

    @Test("unknown channel names do not resolve", arguments: ["", "beta", "debug:", "org.example.app", "./session.json"])
    func unknownChannels(name: String) {
        #expect(SessionSnapshotFileLocation.bundleIdentifier(forChannel: name) == nil)
    }

    @Test("each channel resolves to its own session file under Application Support/cmux")
    func perChannelSnapshotPaths() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let repository = makeRepository(appSupport: dir, bundleIdentifier: "com.cmuxterm.app")
        let expectations = [
            "stable": "session-com.cmuxterm.app.json",
            "nightly": "session-com.cmuxterm.app.nightly.json",
            "rc": "session-com.cmuxterm.app.rc.json",
            "staging": "session-com.cmuxterm.app.staging.json",
            "debug:feature-x": "session-com.cmuxterm.app.debug.feature-x.json",
        ]
        for (channel, fileName) in expectations {
            let bundleId = try #require(SessionSnapshotFileLocation.bundleIdentifier(forChannel: channel))
            let url = try #require(repository.snapshotFileURL(bundleIdentifier: bundleId))
            #expect(url.path == dir.appendingPathComponent("cmux/\(fileName)").path)
        }
        // The running install's own file is the same one it saves to.
        #expect(
            repository.snapshotFileURL(bundleIdentifier: "com.cmuxterm.app")
                == repository.defaultSnapshotFileURL()
        )
    }

    // MARK: - Import from another channel

    @Test("stable imports the nightly snapshot without writing either install's files")
    func importFromOtherChannelIsReadOnly() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let stable = makeRepository(appSupport: dir, bundleIdentifier: "com.cmuxterm.app")
        let nightly = makeRepository(appSupport: dir, bundleIdentifier: "com.cmuxterm.app.nightly")
        let nightlySnapshot = snapshot("nightly-window")
        let stableSnapshot = snapshot("stable-window")
        #expect(nightly.save(nightlySnapshot, fileURL: nil))
        #expect(stable.save(stableSnapshot, fileURL: nil))
        let nightlyURL = try #require(nightly.defaultSnapshotFileURL())
        let nightlyBytes = try Data(contentsOf: nightlyURL)
        let stableBytes = try Data(contentsOf: try #require(stable.defaultSnapshotFileURL()))

        let imported = try stable.importableSnapshot(bundleIdentifier: "com.cmuxterm.app.nightly").get()

        #expect(imported.snapshot == nightlySnapshot)
        #expect(imported.fileURL == nightlyURL)
        #expect(try Data(contentsOf: nightlyURL) == nightlyBytes)
        #expect(try Data(contentsOf: try #require(stable.defaultSnapshotFileURL())) == stableBytes)
        #expect(!FileManager.default.fileExists(atPath: try #require(nightly.manualRestoreSnapshotFileURL()).path))
    }

    @Test("import falls back to the channel's -previous backup when its primary is unusable")
    func importFallsBackToBackup() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let stable = makeRepository(appSupport: dir, bundleIdentifier: "com.cmuxterm.app")
        let nightly = makeRepository(appSupport: dir, bundleIdentifier: "com.cmuxterm.app.nightly")
        let backupSnapshot = snapshot("backup")
        let backupURL = try #require(nightly.manualRestoreSnapshotFileURL())
        #expect(nightly.save(backupSnapshot, fileURL: backupURL))
        try write("corrupt", to: try #require(nightly.defaultSnapshotFileURL()))

        let imported = try stable.importableSnapshot(bundleIdentifier: "com.cmuxterm.app.nightly").get()

        #expect(imported.snapshot == backupSnapshot)
        #expect(imported.fileURL == backupURL)
    }

    @Test("importing a channel with no snapshot reports its primary file as missing")
    func importMissingChannel() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let stable = makeRepository(appSupport: dir, bundleIdentifier: "com.cmuxterm.app")

        let result = stable.importableSnapshot(bundleIdentifier: "com.cmuxterm.app.rc")

        guard case .fileNotFound(let url)? = result.failure else {
            Issue.record("expected fileNotFound, got \(result)")
            return
        }
        #expect(url.path == dir.appendingPathComponent("cmux/session-com.cmuxterm.app.rc.json").path)
    }

    @Test("an install refuses to import its own live snapshot, by channel or by path")
    func importRefusesOwnLiveSnapshot() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let stable = makeRepository(appSupport: dir, bundleIdentifier: "com.cmuxterm.app")
        #expect(stable.save(snapshot("live"), fileURL: nil))
        let primaryURL = try #require(stable.defaultSnapshotFileURL())
        let backupURL = try #require(stable.manualRestoreSnapshotFileURL())
        #expect(stable.save(snapshot("previous-launch"), fileURL: backupURL))

        guard case .liveSnapshot? = stable.importableSnapshot(bundleIdentifier: "com.cmuxterm.app").failure else {
            Issue.record("expected liveSnapshot for the install's own channel")
            return
        }
        guard case .liveSnapshot? = stable.importableSnapshot(fileURL: primaryURL).failure else {
            Issue.record("expected liveSnapshot for the install's own primary path")
            return
        }
        // Its previous launch stays importable by path (what restore-session reopens).
        #expect(try stable.importableSnapshot(fileURL: backupURL).get().snapshot == snapshot("previous-launch"))
    }

    // MARK: - Invalid files

    @Test("invalid files report why they cannot be imported")
    func invalidFileErrors() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let repository = makeRepository(appSupport: dir, bundleIdentifier: "com.cmuxterm.app")

        let missing = dir.appendingPathComponent("missing.json")
        #expect(repository.importableSnapshot(fileURL: missing).failure == .fileNotFound(missing))

        let notJSON = dir.appendingPathComponent("not-json.json")
        try write("hello", to: notJSON)
        #expect(repository.importableSnapshot(fileURL: notJSON).failure == .notASessionSnapshot(notJSON))

        let noVersion = dir.appendingPathComponent("no-version.json")
        try write(#"{"windows":[{"name":"w"}]}"#, to: noVersion)
        #expect(repository.importableSnapshot(fileURL: noVersion).failure == .notASessionSnapshot(noVersion))

        let wrongShape = dir.appendingPathComponent("wrong-shape.json")
        try write(#"{"version":1,"windows":"nope"}"#, to: wrongShape)
        #expect(repository.importableSnapshot(fileURL: wrongShape).failure == .notASessionSnapshot(wrongShape))

        let newer = dir.appendingPathComponent("newer.json")
        try write(#"{"version":7,"somethingNew":{}}"#, to: newer)
        #expect(
            repository.importableSnapshot(fileURL: newer).failure
                == .newerSchemaVersion(newer, found: 7, supported: schemaVersion)
        )

        let older = dir.appendingPathComponent("older.json")
        try write(#"{"version":0,"windows":[{"name":"w"}]}"#, to: older)
        #expect(
            repository.importableSnapshot(fileURL: older).failure
                == .olderSchemaVersion(older, found: 0, supported: schemaVersion)
        )

        let empty = dir.appendingPathComponent("empty.json")
        try write(#"{"version":1,"windows":[]}"#, to: empty)
        #expect(repository.importableSnapshot(fileURL: empty).failure == .noWindows(empty))
    }

    // MARK: - Export and round trip

    @Test("export then import round-trips the saved snapshot byte for byte")
    func exportImportRoundTrip() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let nightly = makeRepository(appSupport: dir, bundleIdentifier: "com.cmuxterm.app.nightly")
        let stable = makeRepository(appSupport: dir, bundleIdentifier: "com.cmuxterm.app")
        let saved = snapshot("one", "two")
        #expect(nightly.save(saved, fileURL: nil))
        let destination = dir.appendingPathComponent("exports/nested/session.json")

        let source = try nightly.exportSnapshot(to: destination, overwrite: false).get()

        #expect(source == nightly.defaultSnapshotFileURL())
        #expect(try Data(contentsOf: destination) == Data(contentsOf: source))
        let imported = try stable.importableSnapshot(fileURL: destination).get()
        #expect(imported.snapshot == saved)
        #expect(imported.fileURL == destination)
    }

    @Test("export falls back to the backup when the primary is unusable")
    func exportUsesBackup() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let repository = makeRepository(appSupport: dir, bundleIdentifier: "com.cmuxterm.app")
        let backupURL = try #require(repository.manualRestoreSnapshotFileURL())
        #expect(repository.save(snapshot("backup"), fileURL: backupURL))
        try write("corrupt", to: try #require(repository.defaultSnapshotFileURL()))
        let destination = dir.appendingPathComponent("out.json")

        #expect(try repository.exportSnapshot(to: destination, overwrite: false).get() == backupURL)
        #expect(try repository.importableSnapshot(fileURL: destination).get().snapshot == snapshot("backup"))
    }

    @Test("export refuses to overwrite without permission, to clobber its own files, or to write nothing")
    func exportRefusals() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let repository = makeRepository(appSupport: dir, bundleIdentifier: "com.cmuxterm.app")
        let destination = dir.appendingPathComponent("out.json")

        #expect(repository.exportSnapshot(to: destination, overwrite: false).failure == .noSnapshot)
        #expect(!FileManager.default.fileExists(atPath: destination.path))

        #expect(repository.save(snapshot("w"), fileURL: nil))
        try write("keep me", to: destination)
        #expect(repository.exportSnapshot(to: destination, overwrite: false).failure == .destinationExists(destination))
        #expect(try String(contentsOf: destination, encoding: .utf8) == "keep me")
        _ = try repository.exportSnapshot(to: destination, overwrite: true).get()
        #expect(try repository.importableSnapshot(fileURL: destination).get().snapshot == snapshot("w"))

        let primaryURL = try #require(repository.defaultSnapshotFileURL())
        let backupURL = try #require(repository.manualRestoreSnapshotFileURL())
        #expect(
            repository.exportSnapshot(to: primaryURL, overwrite: true).failure
                == .destinationIsLiveSnapshot(primaryURL.standardizedFileURL)
        )
        #expect(
            repository.exportSnapshot(to: backupURL, overwrite: true).failure
                == .destinationIsLiveSnapshot(backupURL.standardizedFileURL)
        )
    }

    // MARK: - Newer schema side files

    @Test("a newer-schema snapshot is copied to a schema side file that can be imported later")
    func newerSchemaSideFile() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let repository = makeRepository(appSupport: dir, bundleIdentifier: "com.cmuxterm.app")
        let primaryURL = try #require(repository.defaultSnapshotFileURL())
        let newerText = #"{"version":2,"windows":[{"name":"future"}]}"#
        try write(newerText, to: primaryURL)

        let sideURL = try #require(repository.preserveNewerSchemaSnapshot(fileURL: primaryURL))

        #expect(sideURL.lastPathComponent == "session-com.cmuxterm.app.schema-v2.json")
        #expect(try String(contentsOf: sideURL, encoding: .utf8) == newerText)
        let newerBuild = SessionSnapshotRepository<TransferSnapshotFixture>(
            schemaVersion: 2,
            bundleIdentifier: "com.cmuxterm.app",
            appSupportDirectory: dir
        )
        #expect(try newerBuild.importableSnapshot(fileURL: sideURL).get().snapshot.windows.map(\.name) == ["future"])

        // Current and older snapshots need no side file.
        #expect(repository.save(snapshot("now"), fileURL: nil))
        #expect(repository.preserveNewerSchemaSnapshot(fileURL: primaryURL) == nil)
    }
}

private extension Result {
    var failure: Failure? {
        if case .failure(let error) = self { return error }
        return nil
    }
}
