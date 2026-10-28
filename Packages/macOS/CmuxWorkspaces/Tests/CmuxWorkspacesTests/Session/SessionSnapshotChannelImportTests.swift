import Foundation
import Testing
@testable import CmuxWorkspaces

@Suite("Session channel import bounds")
struct SessionSnapshotChannelImportTests {
    private func snapshotData(paddingTokens: Int) -> Data {
        Data(("{\"version\":1,\"windows\":[\"terminal\"],\"pad\":["
            + String(repeating: "0,", count: paddingTokens) + "0]}").utf8)
    }

    @Test("channel primary and backup imports admit supported large sessions", arguments: [false, true])
    func channelImportRetainsLargeSession(useBackup: Bool) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = SessionSnapshotRepository<SessionSnapshotChannelImportFixture>(
            schemaVersion: 1, bundleIdentifier: "com.cmuxterm.tests", appSupportDirectory: directory
        )
        let location = SessionSnapshotFileLocation(appSupportDirectory: directory)
        let source = useBackup
            ? location.backupFileURL(bundleIdentifier: "com.cmuxterm.other")
            : location.primaryFileURL(bundleIdentifier: "com.cmuxterm.other")
        try FileManager.default.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
        try snapshotData(paddingTokens: 1_200_000).write(to: source)

        guard case .success(let imported) = repository.importableSnapshot(bundleIdentifier: "com.cmuxterm.other") else {
            Issue.record("a channel session within the restore budget must import")
            return
        }
        #expect(imported.snapshot.windows == ["terminal"])
        #expect(imported.fileURL == source)
        guard case .failure(.resourceLimitExceeded) = repository.importableSnapshot(fileURL: source) else {
            Issue.record("explicit file imports must retain their smaller untrusted token budget")
            return
        }
    }

    @Test("channel primary and backup imports retain a predecode token bound", arguments: [false, true])
    func channelImportRejectsExcessiveTokens(useBackup: Bool) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = SessionSnapshotRepository<SessionSnapshotChannelImportFixture>(
            schemaVersion: 1, bundleIdentifier: "com.cmuxterm.tests", appSupportDirectory: directory
        )
        let location = SessionSnapshotFileLocation(appSupportDirectory: directory)
        let source = useBackup
            ? location.backupFileURL(bundleIdentifier: "com.cmuxterm.other")
            : location.primaryFileURL(bundleIdentifier: "com.cmuxterm.other")
        try FileManager.default.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
        try snapshotData(paddingTokens: 2_200_000).write(to: source)

        guard case .failure(.resourceLimitExceeded) = repository.importableSnapshot(bundleIdentifier: "com.cmuxterm.other") else {
            Issue.record("channel imports must reject excessive object graphs before decoding")
            return
        }
    }

    @Test("non-UTF8 bytes are rejected even within the file token budget", arguments: [false, true])
    func encodingGuardRejectsSmallPayloads(useBOM: Bool) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let repository = SessionSnapshotRepository<SessionSnapshotChannelImportFixture>(
            schemaVersion: 1, bundleIdentifier: "com.cmuxterm.tests", appSupportDirectory: directory
        )
        let source = directory.appendingPathComponent("import.json")
        let data = useBOM ? Data([0xFF, 0xFE]) + snapshotData(paddingTokens: 1)
            : Data("{\"version\":1,\"windows\":[\"".utf8) + Data([0xE9]) + Data("\"]}".utf8)
        try data.write(to: source)
        guard case .failure(.resourceLimitExceeded) = repository.importableSnapshot(fileURL: source) else {
            Issue.record("the encoding guard must reject invalid UTF-8 before JSON decoding")
            return
        }
    }
}
