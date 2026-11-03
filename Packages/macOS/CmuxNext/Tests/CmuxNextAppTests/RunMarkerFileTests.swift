@testable import CmuxNextApp
import CmuxNextCompat
import CmuxNextCrashReporting
import Foundation
import Testing

/// The run marker (`run.json`) carries the crash context's footprint, a `task_info` of the whole task that waits for
/// the kernel's VM map. A diagnostic never makes a system call on the main thread (v229, 2026-10-30: a diagnostic's
/// process read stalled the main thread 1,261 ms), so the marker's bytes, and the footprint in them, are made on
/// the marker's writer queue.
@Suite(.timeLimit(.minutes(1))) struct RunMarkerFileTests {
    /// Records where each encode ran. Nonisolated: the encode calls it on the marker's writer queue, as the product
    /// runs it (this target is main-actor by default); the Mutex makes it safe from any thread.
    nonisolated final class Encodes: Sendable {
        // concurrency-allow: test recorder; the encode appends from the writer queue, the test reads after the write.
        private let state = Mutex<[Bool]>([])

        func note(onMain: Bool) { state.withLock { $0.append(onMain) } }
        var onMain: [Bool] { state.withLock { $0 } }
    }

    @MainActor @Test func theMarkerBytesAreMadeOffTheMainThread() async {
        let encodes = Encodes()
        let directory = URL(fileURLWithPath: "/nonexistent-run-marker-test", isDirectory: true)
        let file = RunMarkerFile(url: directory.appending(path: "run.json"), signalURL: directory.appending(path: "run.signal"),
                                 writer: { _, _ in })
        // As AppRunMarker.record(context:) submits on the main actor.
        let ticket = file.submit(encoding: {
            encodes.note(onMain: pthread_main_np() != 0)
            return Data("{}".utf8)
        })
        #expect(ticket != 0)
        #expect(await file.written(ticket, timeout: .seconds(30)))
        #expect(encodes.onMain == [false], "the marker's bytes were made on the main thread")
    }

    /// Quit's close waits for at most one disk write, never for bytes being made (their footprint read can wait for
    /// the kernel), and nothing is written after it. The encode here holds until the close has returned: a close
    /// that waited for it never returns, and the suite's time limit fails the test.
    @Test func closeDoesNotWaitForBytesBeingMade() async {
        let gate = DispatchSemaphore(value: 0)
        let writes = Encodes()
        let directory = URL(fileURLWithPath: "/nonexistent-run-marker-test", isDirectory: true)
        let file = RunMarkerFile(url: directory.appending(path: "run.json"), signalURL: directory.appending(path: "run.signal"),
                                 writer: { _, _ in writes.note(onMain: false) })
        let (started, began) = AsyncStream<Void>.makeStream()
        let ticket = file.submit(encoding: {
            began.yield()
            gate.wait()
            return Data("{}".utf8)
        })
        var iterator = started.makeAsyncIterator()
        _ = await iterator.next()
        await Task.detached { file.close() }.value
        gate.signal()
        await file.drained()
        #expect(await file.written(ticket, timeout: .seconds(30)), "a closed file answers true")
        #expect(writes.onMain.isEmpty, "nothing is written after close")
        #expect(file.writeCount == 0)
    }

    /// The bytes carry the footprint read when they are made, not the snapshot's.
    @Test func theEncodingReadsTheFootprintWhenItRuns() throws {
        var run = PreviousRun(pid: 4242, launched: Date(timeIntervalSince1970: 1_000), recovery: false, survived: false, signal: nil)
        run.context = CrashContext(updated: Date(timeIntervalSince1970: 1_000), windows: 1, workspaces: 1, tabKinds: ["pty"],
                                   focusedPane: "pty", browserEngine: nil, browserFailures: 0, footprintMegabytes: 0, actions: [])
        let data = try #require(AppRunMarker.encoding(run, footprint: { 977 })())
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        #expect(try decoder.decode(PreviousRun.self, from: data).context?.footprintMegabytes == 977)
    }
}
