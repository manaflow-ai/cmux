import CmuxNextCompat
import Dispatch
import Testing

/// #17587: a file the first window draws (the launch snapshot, the saved sidebars) is read and
/// decoded on a background task begun in `main` (`LaunchRead`); the window build only takes the
/// value, and the file is read once, never twice.
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

    /// The background read is still running when the window takes the value: the main thread waits
    /// for the rest of it (and marks that it paid), never starts a second read from zero.
    @MainActor @Test func aTakeWhileTheBackgroundReadRunsWaitsForItAndNeverReadsAgain() async {
        let counts = Counts()
        // A test gate, not a lock: the read holds until the take has begun waiting (the take marks just before it waits).
        let gate = DispatchSemaphore(value: 0)
        let (started, startedNow) = AsyncStream<Void>.makeStream()
        let read = LaunchRead("test_file", readOnMain: { name in
            #expect(name == "launch_read_on_main.test_file")
            _ = counts.marks.add(1, ordering: .relaxed)
            gate.signal()
        }) {
            _ = counts.reads.add(1, ordering: .relaxed)
            startedNow.yield()
            gate.wait()
            return ["workspace-1"]
        }
        for await _ in started { break }
        #expect(read.take() == ["workspace-1"], "the value of the read that was running")
        #expect(counts.reads.load(ordering: .relaxed) == 1, "the main thread waited for the running read instead of reading again")
        #expect(counts.marks.load(ordering: .relaxed) == 1, "the wait on the main thread is marked for the launch guard")
        await read.backgroundReadFinished()
        #expect(counts.reads.load(ordering: .relaxed) == 1)
    }

    /// Off the main thread a take that waits is not marked: the guard counts only the main thread.
    @Test func aTakeOffTheMainThreadIsNotMarked() async {
        let counts = Counts()
        let read = LaunchRead("test_file", readOnMain: { _ in _ = counts.marks.add(1, ordering: .relaxed) }) {
            _ = counts.reads.add(1, ordering: .relaxed)
            return 7
        }
        let value = await Task.detached { read.take() }.value
        #expect(value == 7)
        await read.backgroundReadFinished()
        #expect(counts.reads.load(ordering: .relaxed) == 1, "read once, by the background task or by the taker, never both")
        #expect(counts.marks.load(ordering: .relaxed) == 0)
    }
}
