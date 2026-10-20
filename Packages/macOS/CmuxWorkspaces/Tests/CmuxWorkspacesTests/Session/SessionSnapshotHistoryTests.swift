import Foundation
import Testing
@testable import CmuxWorkspaces

private struct HistorySnapshotFixture: SessionSnapshotRepresenting, Equatable {
    var version: Int
    var workspaces: [[String]]

    var hasWindows: Bool { true }
    var richness: SessionSnapshotRichness {
        SessionSnapshotRichness(workspaces: workspaces.count, panels: workspaces.reduce(0) { $0 + $1.count })
    }
}

@Suite("Session snapshot history")
struct SessionSnapshotHistoryTests {
    private let schemaVersion = 1

    private func makeRepository(root: URL, limit: Int = 3) -> SessionSnapshotRepository<HistorySnapshotFixture> {
        SessionSnapshotRepository(
            schemaVersion: schemaVersion,
            bundleIdentifier: "com.cmuxterm.app",
            appSupportDirectory: root,
            historyLimit: limit
        )
    }

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-session-history-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    /// Saves `snapshot` as the primary, then archives it the way launch does.
    @discardableResult
    private func archiveLaunch(
        _ repository: SessionSnapshotRepository<HistorySnapshotFixture>,
        _ snapshot: HistorySnapshotFixture,
        at seconds: TimeInterval
    ) throws -> SessionSnapshotHistoryEntry? {
        let primary = try #require(repository.defaultSnapshotFileURL())
        #expect(repository.save(snapshot, fileURL: primary))
        return repository.archiveSnapshotToHistory(
            fileURL: primary,
            richness: snapshot.richness,
            archivedAt: Date(timeIntervalSince1970: seconds)
        )
    }

    @Test("quick trivial relaunches never rotate out the last full layout")
    func trivialRelaunchesKeepRichest() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = makeRepository(root: root, limit: 3)
        let rich = HistorySnapshotFixture(version: schemaVersion, workspaces: [["a", "b"], ["c"], ["d", "e"]])
        try archiveLaunch(repository, rich, at: 1_000)
        for index in 1...6 {
            let trivial = HistorySnapshotFixture(version: schemaVersion, workspaces: [["t\(index)"]])
            try archiveLaunch(repository, trivial, at: 1_000 + TimeInterval(index))
        }

        let entries = repository.historyEntries()
        #expect(entries.count == 3)
        #expect(entries.contains { $0.richness == rich.richness })
        let richEntry = try #require(entries.first { $0.richness == rich.richness })
        #expect(repository.load(fileURL: richEntry.fileURL) == rich)
        #expect(entries.first?.archivedAt == Date(timeIntervalSince1970: 1_006))
    }

    @Test("identical consecutive snapshots are archived once")
    func identicalSnapshotsDeduplicate() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = makeRepository(root: root)
        let snapshot = HistorySnapshotFixture(version: schemaVersion, workspaces: [["a"]])
        #expect(try archiveLaunch(repository, snapshot, at: 10) != nil)
        #expect(try archiveLaunch(repository, snapshot, at: 20) == nil)
        #expect(repository.historyEntries().count == 1)
    }

    @Test("history file names round-trip and ignore other bundles")
    func historyNamesAreBundleScoped() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = makeRepository(root: root)
        let other = SessionSnapshotRepository<HistorySnapshotFixture>(
            schemaVersion: schemaVersion,
            bundleIdentifier: "com.cmuxterm.app.debug.echo",
            appSupportDirectory: root
        )
        try archiveLaunch(other, HistorySnapshotFixture(version: schemaVersion, workspaces: [["x"]]), at: 5)
        #expect(repository.historyEntries().isEmpty)
        let entry = try #require(
            try archiveLaunch(repository, HistorySnapshotFixture(version: schemaVersion, workspaces: [["a", "b"]]), at: 7.25)
        )
        #expect(repository.historyEntries() == [entry])
        #expect(entry.richness == SessionSnapshotRichness(workspaces: 1, panels: 2))
    }
}

@Suite("Session snapshot overwrite guard")
struct SessionSnapshotOverwriteGuardTests {
    private let launch = Date(timeIntervalSince1970: 1_000)
    private let rich = SessionSnapshotRichness(workspaces: 5, panels: 9)
    private let trivial = SessionSnapshotRichness(workspaces: 1, panels: 1)

    @Test("an empty relaunch holds writes until it matures")
    func emptyRelaunchHolds() {
        var guardState = SessionSnapshotOverwriteGuard(baseline: rich, launchDate: launch, maturityInterval: 300)
        #expect(guardState.evaluate(candidate: trivial, structure: 1, now: launch.addingTimeInterval(1)) == .hold)
        #expect(guardState.evaluate(candidate: trivial, structure: 1, now: launch.addingTimeInterval(60)) == .hold)
        #expect(guardState.evaluate(candidate: trivial, structure: 1, now: launch.addingTimeInterval(300)) == .write)
        #expect(guardState.isMature)
        #expect(guardState.evaluate(candidate: trivial, structure: 1, now: launch.addingTimeInterval(301)) == .write)
    }

    @Test("a layout change after launch counts as user intent")
    func structureChangeMatures() {
        var guardState = SessionSnapshotOverwriteGuard(baseline: rich, launchDate: launch, maturityInterval: 300)
        #expect(guardState.evaluate(candidate: trivial, structure: 1, now: launch.addingTimeInterval(1)) == .hold)
        #expect(guardState.evaluate(candidate: trivial, structure: 2, now: launch.addingTimeInterval(2)) == .write)
        #expect(guardState.evaluate(candidate: .empty, structure: 3, now: launch.addingTimeInterval(3)) == .write)
    }

    @Test("a full restore writes immediately")
    func fullRestoreWrites() {
        var guardState = SessionSnapshotOverwriteGuard(baseline: rich, launchDate: launch)
        #expect(guardState.evaluate(candidate: rich, structure: 1, now: launch) == .write)
        #expect(guardState.evaluate(candidate: trivial, structure: 1, now: launch) == .write)
    }

    @Test("a first launch with no prior snapshot never holds")
    func noBaselineWrites() {
        var guardState = SessionSnapshotOverwriteGuard(baseline: .empty, launchDate: launch)
        #expect(guardState.evaluate(candidate: trivial, structure: 1, now: launch) == .write)
    }
}
