import Foundation
import Testing
import CmuxCore
@testable import CmuxWorkspaces

/// A test `SelectedWorkspaceReading` that lets the test drive the snapshot
/// stream by hand and observe model dedup behavior.
@MainActor
private final class FakeSelectedWorkspaceReading: SelectedWorkspaceReading {
    let directorySnapshots: AsyncStream<SelectedWorkspaceDirectorySnapshot>
    private let continuation: AsyncStream<SelectedWorkspaceDirectorySnapshot>.Continuation

    init() {
        (directorySnapshots, continuation) = AsyncStream.makeStream(
            of: SelectedWorkspaceDirectorySnapshot.self
        )
    }

    func emit(_ snapshot: SelectedWorkspaceDirectorySnapshot) {
        continuation.yield(snapshot)
    }

    func finish() {
        continuation.finish()
    }
}

private func makeSnapshot(
    workspaceId: UUID,
    currentDirectory: String?
) -> SelectedWorkspaceDirectorySnapshot {
    SelectedWorkspaceDirectorySnapshot(
        workspaceId: workspaceId,
        currentDirectory: currentDirectory,
        remoteConfiguration: nil,
        remoteConnectionState: nil,
        remoteConnectionDetail: nil,
        remoteDaemonStatus: nil,
        activeRemoteTerminalSessionCount: 0
    )
}

/// Spins the cooperative pool until `condition` holds or a bounded number of
/// yields elapse, so the stream-consuming task can deliver pending snapshots.
@MainActor
private func waitUntil(_ condition: () -> Bool) async {
    for _ in 0..<1000 {
        if condition() { return }
        await Task.yield()
    }
}

@MainActor
@Suite("SelectedWorkspaceDirectoryModel")
struct SelectedWorkspaceDirectoryModelTests {
    @Test("Starts at generation 0 before any snapshot")
    func startsAtZero() {
        let model = SelectedWorkspaceDirectoryModel()
        #expect(model.directoryChangeGeneration == 0)
    }

    @Test("First snapshot bumps the generation to 1 (legacy first-sink behavior)")
    func firstSnapshotBumps() async {
        let reading = FakeSelectedWorkspaceReading()
        let model = SelectedWorkspaceDirectoryModel()
        model.wire(reading: reading)

        reading.emit(makeSnapshot(workspaceId: UUID(), currentDirectory: "/a"))
        await waitUntil { model.directoryChangeGeneration == 1 }
        #expect(model.directoryChangeGeneration == 1)
    }

    @Test("Distinct snapshots each advance the generation")
    func distinctSnapshotsAdvance() async {
        let reading = FakeSelectedWorkspaceReading()
        let model = SelectedWorkspaceDirectoryModel()
        model.wire(reading: reading)
        let id = UUID()

        reading.emit(makeSnapshot(workspaceId: id, currentDirectory: "/a"))
        await waitUntil { model.directoryChangeGeneration == 1 }
        reading.emit(makeSnapshot(workspaceId: id, currentDirectory: "/b"))
        await waitUntil { model.directoryChangeGeneration == 2 }

        #expect(model.directoryChangeGeneration == 2)
    }

    @Test("Equal consecutive snapshots do NOT advance (legacy removeDuplicates)")
    func equalSnapshotsAreDeduped() async {
        let reading = FakeSelectedWorkspaceReading()
        let model = SelectedWorkspaceDirectoryModel()
        model.wire(reading: reading)
        let id = UUID()
        let snapshot = makeSnapshot(workspaceId: id, currentDirectory: "/a")

        reading.emit(snapshot)
        await waitUntil { model.directoryChangeGeneration == 1 }
        reading.emit(snapshot)
        reading.emit(snapshot)
        // Give the consumer task room to process the duplicates.
        for _ in 0..<50 { await Task.yield() }

        #expect(model.directoryChangeGeneration == 1)
    }

    @Test("Re-wiring the same reader is a no-op")
    func reWiringSameReaderIsNoOp() async {
        let reading = FakeSelectedWorkspaceReading()
        let model = SelectedWorkspaceDirectoryModel()
        model.wire(reading: reading)
        reading.emit(makeSnapshot(workspaceId: UUID(), currentDirectory: "/a"))
        await waitUntil { model.directoryChangeGeneration == 1 }

        // Second wire to the SAME instance must not resubscribe or reset.
        model.wire(reading: reading)
        reading.emit(makeSnapshot(workspaceId: UUID(), currentDirectory: "/b"))
        await waitUntil { model.directoryChangeGeneration == 2 }

        #expect(model.directoryChangeGeneration == 2)
    }
}
