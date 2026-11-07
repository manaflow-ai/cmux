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

/// Snapshot root carrying a pane/split tree shaped like the app's
/// `SessionWorkspaceLayoutSnapshot` wire format (two JSON levels per split).
private struct DeepLayoutSnapshotFixture: SessionSnapshotRepresenting, Equatable {
    struct Split: Codable, Equatable, Sendable {
        var dividerPosition: Double
        var first: Node
        var second: Node
    }

    indirect enum Node: Codable, Equatable, Sendable {
        case pane(String)
        case split(Split)

        private enum CodingKeys: String, CodingKey {
            case type
            case pane
            case split
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            if try container.decode(String.self, forKey: .type) == "pane" {
                self = .pane(try container.decode(String.self, forKey: .pane))
            } else {
                self = .split(try container.decode(Split.self, forKey: .split))
            }
        }

        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .pane(let name):
                try container.encode("pane", forKey: .type)
                try container.encode(name, forKey: .pane)
            case .split(let split):
                try container.encode("split", forKey: .type)
                try container.encode(split, forKey: .split)
            }
        }
    }

    var version: Int
    var layout: Node

    var hasWindows: Bool { true }

    /// A linear tree: every split nests the next split in its second child.
    static func linear(depth: Int) -> Self {
        var node = Node.pane("leaf")
        for index in 0..<depth {
            node = .split(Split(dividerPosition: 0.5, first: .pane("p\(index)"), second: node))
        }
        return Self(version: 1, layout: node)
    }
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
        bundleIdentifier: String? = "com.cmuxterm.tests"
    ) -> SessionSnapshotRepository<SnapshotFixture> {
        SessionSnapshotRepository(
            schemaVersion: schemaVersion,
            bundleIdentifier: bundleIdentifier,
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

    @Test("a primary written by a newer schema survives the startup sync and the next save")
    func newerSchemaPrimarySurvivesNextSave() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let repository = makeRepository(appSupport: dir)
        let primaryURL = try #require(repository.defaultSnapshotFileURL())
        // A newer cmux wrote this; a downgraded build cannot restore it, but
        // must not destroy it with its own next autosave either.
        let newerData = Data(
            #"{"futureField":true,"version":\#(schemaVersion + 1),"windows":[{"name":"newer"}]}"#.utf8
        )
        try FileManager.default.createDirectory(
            at: primaryURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try newerData.write(to: primaryURL)

        repository.syncManualRestoreSnapshotCache()
        #expect(repository.save(makeSnapshot(windowNames: ["current"]), fileURL: nil))

        let survivors = try FileManager.default
            .contentsOfDirectory(at: primaryURL.deletingLastPathComponent(), includingPropertiesForKeys: nil)
            .filter { (try? Data(contentsOf: $0)) == newerData }
        #expect(survivors.count == 1, "the newer-schema snapshot must be kept on disk")
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

    @Test("deep split layouts save and load off the main thread without overflowing the worker stack")
    func deepLayoutRoundTripsOnBackgroundQueue() async throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let repository = SessionSnapshotRepository<DeepLayoutSnapshotFixture>(
            schemaVersion: schemaVersion,
            bundleIdentifier: "com.cmuxterm.tests",
            appSupportDirectory: dir
        )
        // 200 splits is 400 JSON levels: inside Foundation's nesting limit,
        // but deeper than a 512 KB dispatch worker stack can encode
        // (manaflow-ai/cmux#4656). The autosave path codes on such a queue.
        let snapshot = DeepLayoutSnapshotFixture.linear(depth: 200)
        let loaded = await withCheckedContinuation { continuation in
            DispatchQueue(label: "cmux.tests.sessionPersistence", qos: .utility).async {
                let saved = repository.save(snapshot, fileURL: nil)
                continuation.resume(returning: saved ? repository.load(fileURL: nil) : nil)
            }
        }
        #expect(loaded == snapshot)
    }

    @Test("the app's own snapshot loads even when one string is several MiB")
    func ownSnapshotWithLargeStringLoads() throws {
        // A text box draft has no size limit, so a pasted log can put a
        // multi-megabyte string in the app's own snapshot. Losing the whole
        // session over it would be far worse than the memory it costs.
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let repository = makeRepository(appSupport: dir)
        let snapshot = makeSnapshot(windowNames: [String(repeating: "x", count: 3 * 1024 * 1024)])

        #expect(repository.save(snapshot, fileURL: nil))
        #expect(repository.loadStartupSnapshot() == snapshot)
    }

    // Foundation's own parser rejects nesting past 512 too, so this pins the
    // outcome rather than proving the guard; the token boundary test does that.
    @Test("import rejects JSON nested past the decode limit before decoding")
    func overlyNestedJSONIsRejectedBeforeDecode() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let repository = makeRepository(appSupport: dir)
        let fileURL = dir.appendingPathComponent("nested.json")
        let depth = 600
        let data = Data("{\"version\":1,\"windows\":[{\"name\":\"w\",\"nested\":".utf8)
            + Data(String(repeating: "[", count: depth).utf8)
            + Data(String(repeating: "]", count: depth).utf8)
            + Data("}]}".utf8)
        try data.write(to: fileURL)

        guard case .failure(.notASessionSnapshot) = repository.importableSnapshot(fileURL: fileURL) else {
            Issue.record("expected deeply nested JSON to be rejected before decoding")
            return
        }
    }

    /// The structural tokens the import guard counts: `{ } [ ] : ,` outside
    /// strings. Mirrors the guard so the boundary tests can aim at it exactly.
    private func structuralTokenCount(_ data: Data) -> Int {
        var count = 0
        var inString = false
        var escaped = false
        for byte in data {
            if inString {
                if escaped { escaped = false } else if byte == 92 { escaped = true } else if byte == 34 { inString = false }
                continue
            }
            switch byte {
            case 34: inString = true
            case 91, 93, 123, 125, 58, 44: count += 1
            default: break
            }
        }
        return count
    }

    /// A one-window snapshot whose ignored `pad` array brings the file to
    /// exactly `tokens` structural tokens.
    private func snapshotData(structuralTokens tokens: Int) -> Data {
        func json(padCount: Int) -> Data {
            Data(("{\"pad\":[" + Array(repeating: "0", count: padCount).joined(separator: ",")
                + "],\"version\":1,\"windows\":[{\"name\":\"w\"}]}").utf8)
        }
        let base = structuralTokenCount(json(padCount: 1))
        let data = json(padCount: tokens - base + 1)
        precondition(structuralTokenCount(data) == tokens)
        return data
    }

    @Test("the app's own snapshot loads even past the import token limit")
    func ownSnapshotOverImportTokenLimitLoads() throws {
        // About 110-345 tokens per panel: a few thousand agent panels cross
        // the untrusted-import limit. The user's own session (and its
        // backups) must still load so the restore budget can trim it.
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let repository = makeRepository(appSupport: dir)
        let primaryURL = try #require(repository.snapshotFileURL(bundleIdentifier: "com.cmuxterm.tests"))
        try FileManager.default.createDirectory(
            at: primaryURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try snapshotData(structuralTokens: 1_200_000).write(to: primaryURL)

        #expect(repository.loadStartupSnapshot() == makeSnapshot(windowNames: ["w"]))
    }

    @Test("import accepts exactly 1,000,000 structural tokens and refuses one more")
    func importStructuralTokenLimitBoundary() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let repository = makeRepository(appSupport: dir)
        let atLimit = dir.appendingPathComponent("at-limit.json")
        let overLimit = dir.appendingPathComponent("over-limit.json")
        try snapshotData(structuralTokens: 1_000_000).write(to: atLimit)
        try snapshotData(structuralTokens: 1_000_001).write(to: overLimit)

        guard case .success(let imported) = repository.importableSnapshot(fileURL: atLimit) else {
            Issue.record("expected a file at the token limit to import")
            return
        }
        #expect(imported.snapshot == makeSnapshot(windowNames: ["w"]))
        guard case .failure(.notASessionSnapshot) = repository.importableSnapshot(fileURL: overLimit) else {
            Issue.record("expected a file one token over the limit to be refused before decoding")
            return
        }
    }

    @Test("an empty import file is not a session snapshot")
    func emptyImportFileIsNotASessionSnapshot() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let repository = makeRepository(appSupport: dir)
        let fileURL = dir.appendingPathComponent("empty.json")
        try Data().write(to: fileURL)

        guard case .failure(.notASessionSnapshot) = repository.importableSnapshot(fileURL: fileURL) else {
            Issue.record("expected an empty file to read as not a session snapshot")
            return
        }
    }
}
