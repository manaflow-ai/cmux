import Foundation
import Testing
@testable import CmuxWorkspaces

@Suite("Agent context handoff verification")
struct AgentContextHandoffVerifierTests {
    @Test("A fresh non-empty handoff file is accepted")
    func acceptsFreshHandoff() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent(".cmux-context-handoff.md")
        try Data("task state\n".utf8).write(to: path)

        let result = await AgentContextHandoffVerifier().verify(
            path: path,
            requestedAt: .distantPast
        )

        #expect(result == .written)
    }

    @Test("A changed handoff is accepted when filesystem mtime is coarse")
    func acceptsChangedSnapshotWithCoarseModificationTime() async {
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        let oldData = Data("old state\n".utf8)
        let newData = Data("new state\n".utf8)
        let metadata = AgentContextHandoffFileMetadata(
            isRegularFile: true,
            modificationDate: timestamp,
            size: oldData.count,
            deviceID: 7,
            fileID: 11
        )
        let updatedMetadata = AgentContextHandoffFileMetadata(
            isRegularFile: true,
            modificationDate: timestamp,
            size: newData.count,
            deviceID: 7,
            fileID: 11
        )
        let fileSystem = SequencedHandoffFileSystem(snapshots: [
            AgentContextHandoffFileSnapshot(metadata: metadata, data: oldData),
            AgentContextHandoffFileSnapshot(metadata: updatedMetadata, data: newData),
        ])
        let verifier = AgentContextHandoffVerifier(fileSystem: fileSystem)
        let path = URL(fileURLWithPath: "/injected/handoff.md")

        let baseline = await verifier.capture(path: path)
        let result = await verifier.verify(
            path: path,
            requestedAt: timestamp.addingTimeInterval(1),
            baseline: baseline
        )

        #expect(result == .written)
    }

    @Test("An unchanged pre-request handoff remains stale")
    func unchangedSnapshotRemainsStaleWithBaseline() async {
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        let data = Data("same state\n".utf8)
        let snapshot = AgentContextHandoffFileSnapshot(
            metadata: AgentContextHandoffFileMetadata(
                isRegularFile: true,
                modificationDate: timestamp,
                size: data.count,
                deviceID: 7,
                fileID: 11
            ),
            data: data
        )
        let fileSystem = SequencedHandoffFileSystem(snapshots: [snapshot, snapshot])
        let verifier = AgentContextHandoffVerifier(fileSystem: fileSystem)
        let path = URL(fileURLWithPath: "/injected/handoff.md")

        let baseline = await verifier.capture(path: path)
        let result = await verifier.verify(
            path: path,
            requestedAt: timestamp.addingTimeInterval(1),
            baseline: baseline
        )

        #expect(result == .stale)
    }

    @Test("Missing and stale handoffs fail closed")
    func missingAndStaleHandoffsFailClosed() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let missing = directory.appendingPathComponent("missing.md")
        #expect(
            await AgentContextHandoffVerifier().verify(
                path: missing,
                requestedAt: .distantPast
            ) == .missing
        )

        let stale = directory.appendingPathComponent("stale.md")
        try Data("old state\n".utf8).write(to: stale)
        #expect(
            await AgentContextHandoffVerifier().verify(
                path: stale,
                requestedAt: .distantFuture
            ) == .stale
        )
    }

    @Test("Blank, empty, and directory handoffs fail closed")
    func blankAndDirectoryHandoffsFailClosed() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let blank = directory.appendingPathComponent("blank.md")
        try Data(" \n\t".utf8).write(to: blank)
        #expect(
            await AgentContextHandoffVerifier().verify(
                path: blank,
                requestedAt: .distantPast
            ) == .empty
        )
        let empty = directory.appendingPathComponent("empty.md")
        try Data().write(to: empty)
        #expect(
            await AgentContextHandoffVerifier().verify(
                path: empty,
                requestedAt: .distantPast
            ) == .empty
        )
        #expect(
            await AgentContextHandoffVerifier().verify(
                path: directory,
                requestedAt: .distantPast
            ) == .notRegularFile
        )
    }

    @Test("Injected filesystem read failures fail closed")
    func injectedReadFailureIsUnreadable() async {
        let fileSystem = StubAgentContextHandoffFileSystem(
            snapshotResult: .failure(.readFailed)
        )

        let result = await AgentContextHandoffVerifier(fileSystem: fileSystem).verify(
            path: URL(fileURLWithPath: "/injected/handoff.md"),
            requestedAt: .distantPast
        )

        #expect(result == .unreadable)
    }

    @Test("A file that grows beyond the bounded read fails closed")
    func growthDuringReadIsUnreadable() async {
        let fileSystem = StubAgentContextHandoffFileSystem(
            snapshotResult: .success(
                AgentContextHandoffFileSnapshot(
                    metadata: AgentContextHandoffFileMetadata(
                        isRegularFile: true,
                        modificationDate: .distantFuture,
                        size: 4
                    ),
                    data: Data(repeating: 0x61, count: 1_048_577)
                )
            )
        )

        let result = await AgentContextHandoffVerifier(fileSystem: fileSystem).verify(
            path: URL(fileURLWithPath: "/injected/handoff.md"),
            requestedAt: .distantPast
        )

        #expect(result == .unreadable)
    }

    @Test("A rename between descriptor validation and path replacement cannot retarget the read")
    func renameBetweenValidationAndReadUsesOriginalDescriptor() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent(".cmux-context-handoff.md")
        let replacement = directory.appendingPathComponent("replacement.md")
        try Data("original handoff\n".utf8).write(to: path)
        let originalData = try Data(contentsOf: path)
        let originalMetadata = AgentContextHandoffFileMetadata(
            isRegularFile: true,
            modificationDate: .distantFuture,
            size: originalData.count
        )
        let fileSystem = RenameBetweenChecksFileSystem(
            path: path,
            replacement: replacement,
            snapshot: AgentContextHandoffFileSnapshot(
                metadata: originalMetadata,
                data: originalData
            )
        )

        let result = await AgentContextHandoffVerifier(fileSystem: fileSystem).verify(
            path: path,
            requestedAt: .distantPast
        )

        #expect(result == .written)
        #expect(String(data: try Data(contentsOf: path), encoding: .utf8) == "replacement\n")
    }

    private struct RenameBetweenChecksFileSystem: AgentContextHandoffFileSystem {
        let path: URL
        let replacement: URL
        let snapshot: AgentContextHandoffFileSnapshot

        func readSnapshot(
            at requestedPath: URL,
            maximumBytes _: Int
        ) async throws -> AgentContextHandoffFileSnapshot? {
            guard requestedPath == path else { return nil }
            try FileManager.default.moveItem(at: path, to: replacement)
            try Data("replacement\n".utf8).write(to: path)
            // The returned value models bytes captured from the descriptor
            // opened before the pathname was renamed/replaced.
            return snapshot
        }
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-agent-context-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false
        )
        return directory
    }

    private actor SequencedHandoffFileSystem: AgentContextHandoffFileSystem {
        var snapshots: [AgentContextHandoffFileSnapshot?]

        init(snapshots: [AgentContextHandoffFileSnapshot]) {
            self.snapshots = snapshots.map(Optional.some)
        }

        func readSnapshot(
            at _: URL,
            maximumBytes _: Int
        ) async throws -> AgentContextHandoffFileSnapshot? {
            guard !snapshots.isEmpty else { return nil }
            return snapshots.removeFirst()
        }
    }
}
