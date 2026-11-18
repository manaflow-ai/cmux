import CmuxNextCompat
import CmuxNextControl
import CmuxNextWakeups
import CmuxNextWakeupsTestSupport
import Dispatch
import Foundation
import Testing

@MainActor
@Suite(.timeLimit(.minutes(1))) struct LaunchRecordWriterTests {
    @Test func debounceWritesLatestStateOffMain() async throws {
        let clock = ManualClock()
        let work = BackgroundWork(cpuWidth: 1, label: "test.launch-record")
        let (written, report) = AsyncStream<(String, Bool)>.makeStream()
        let calls = Mutex(0)
        var socket = "old"
        let writer = LaunchRecordWriter(url: URL(filePath: "/unused/launch-record.bin"), work: work, clock: clock,
            write: { value, _ in
                calls.withLock { $0 += 1 }
                report.yield((value.sessionSocketPath, Thread.isMainThread))
                return true
            }, snapshot: { LaunchRecordSnapshot(sessionSocketPath: socket) })
        writer.schedule()
        socket = "new"
        writer.schedule()
        writer.schedule()
        try await clock.waitForSleeper()
        clock.advance(by: .milliseconds(499))
        #expect(calls.withLock { $0 } == 0)
        clock.advance(by: .milliseconds(1))
        var iterator = written.makeAsyncIterator()
        let result = try #require(await iterator.next())
        await work.shutdown()
        #expect(result.0 == "new")
        #expect(!result.1)
        #expect(calls.withLock { $0 } == 1)
    }

    @Test func quitWaitsForOldWriteThenStoresFinalSnapshot() async throws {
        let work = BackgroundWork(cpuWidth: 1, label: "test.launch-record.quit")
        let release = DispatchSemaphore(value: 0)
        let calls = Mutex<[String]>([])
        let (started, report) = AsyncStream<Void>.makeStream()
        var socket = "old"
        let writer = LaunchRecordWriter(url: URL(filePath: "/unused/launch-record.bin"), work: work,
            write: { value, _ in
                if value.sessionSocketPath == "old" {
                    report.yield(())
                    release.wait()
                }
                calls.withLock { $0.append(value.sessionSocketPath) }
                return true
            }, snapshot: { LaunchRecordSnapshot(sessionSocketPath: socket) })
        let first = Task { await writer.flush() }
        var iterator = started.makeAsyncIterator()
        _ = try #require(await iterator.next())
        socket = "final"
        writer.schedule() // quit cancels this debounce and captures final state immediately
        let unblock = Task { @MainActor in release.signal() }
        await writer.flush()
        await unblock.value
        await first.value
        #expect(calls.withLock { $0 } == ["old", "final"])
        await work.shutdown()
    }
}
