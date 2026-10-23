import CmuxNextCompat
import CmuxNextDaemon
import Foundation
import Testing

/// #17587: a file the first window draws (the launch snapshot, the saved sidebars) is read and
/// decoded on a background task begun in `main`; the window build only takes the value.
@Suite struct LaunchReadTests {
    /// Counts the reads and the `launch_read_on_main.<name>` marks, from any thread.
    final class Counts: Sendable {
        let reads = Atomic<Int>(0)
        let marks = Atomic<Int>(0)
    }

    @MainActor @Test func aFinishedBackgroundReadIsTakenOnTheMainThreadWithoutReadingAgain() async {
        let counts = Counts()
        let read = LaunchRead("test_file", readOnMain: { _ in _ = counts.marks.add(1, ordering: .relaxed) }) {
            _ = counts.reads.add(1, ordering: .relaxed)
            return ["workspace-1", "workspace-2"]
        }
        await read.backgroundReadFinished()
        #expect(read.take() == ["workspace-1", "workspace-2"])
        #expect(counts.reads.load(ordering: .relaxed) == 1, "the main thread did not read the file again")
        #expect(counts.marks.load(ordering: .relaxed) == 0, "no launch_read_on_main mark")
    }

    @Test func theLaunchSnapshotOfASessionWithNoFileIsNone() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "launch-read-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let suite = "launch-read-\(UUID().uuidString)"
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let location = LaunchSnapshotLocation(defaults: { UserDefaults(suiteName: suite) ?? .standard })
        guard case .none = LaunchSnapshot.find(session: "cmux-app-test", stateDirectory: directory, location: location) else {
            Issue.record("a session with no snapshot file found one")
            return
        }
    }
}
