#if DEBUG
import CmuxNextCompat
@testable import CmuxNextControl
import CmuxNextWakeups
import CmuxNextWakeupsTestSupport
import Foundation
import Testing

/// The first frame's thread census: each thread counts toward the library the registry names, and
/// only iroh's tokio pool counts as a runtime the first frame must not have.
@Suite(.timeLimit(.minutes(1)))
struct LaunchThreadCensusTests {
    @Test func eachThreadCountsTowardItsLibrary() {
        let names = ["tokio-runtime-worker", "async-compat/tokio-1", "renderer", "io", "Chrome_IOThread",
                     "com.apple.main-thread", "cmux-next launch warm-up", ""]
        let census = LaunchThreadCensus(names: names, registry: .app)

        #expect(census.threads == names.count)
        #expect(census.libraries == ["iroh": 2, "GhosttyKit": 2, "CEF": 1])
        #expect(census.runtimeThreads == 2)
    }

    @Test func aLaunchWithNoRuntimeThreadReadsZero() {
        let census = LaunchThreadCensus(names: ["renderer", "io", "cf_release", "com.cmuxterm.app.next.blocking-drain"], registry: .app)

        #expect(census.runtimeThreads == 0)
        #expect(census.values.map(\.name) == [LaunchThreadCensus.threadsValue, LaunchThreadCensus.runtimeThreadsValue,
                                             LaunchThreadCensus.ghosttyThreadsValue])
        #expect(census.values.map(\.value) == [4, 0, 3])
    }

    /// A library thread with no row of its own still counts, through its library's name space.
    @Test func aNamespaceThreadWithNoRowCountsTowardItsLibrary() {
        let census = LaunchThreadCensus(names: ["tokio-blocking-1"], registry: .app)

        #expect(census.libraries == ["iroh": 1])
        #expect(census.runtimeThreads == 1)
    }

    /// A reveal-deadline release (``StartupScheduler/firstFrameMissed(_:)`` with nil) is not the first frame: the
    /// census sends nothing then, and the late committed frame takes it.
    @MainActor @Test func aMissedFirstFrameRecordsNoFirstFrameValues() async {
        // One cpu slot: the marker posted after the missed frame runs after a census submitted before it.
        let f = StartupTestScheduler(background: BackgroundWork(cpuWidth: 1, label: "test.census"))
        let (seen, report) = AsyncStream.makeStream(of: String.self)
        LaunchThreadCensus.post(on: f.startup) { name, _ in report.yield(name) }
        f.startup.finishRegistration()
        f.startup.firstFrameMissed(nil)
        f.hand.drain()
        f.startup.post(.afterFirstFrame, "Test.marker", on: .lane(.cpu, .userVisible)) { report.yield("marker") }
        f.hand.drain()
        var reports = seen.makeAsyncIterator()
        let first = await reports.next()
        #expect(first == "marker", "no first-frame value before the frame")

        f.startup.firstFrameCommitted()
        f.hand.drain()
        let expected = [LaunchThreadCensus.threadsValue, LaunchThreadCensus.runtimeThreadsValue, LaunchThreadCensus.ghosttyThreadsValue]
        var names: [String] = []
        for _ in expected { if let name = await reports.next() { names.append(name) } }
        #expect(names == expected, "the committed frame takes the census")
    }

    /// The live read sees a running tokio-named thread of this process as a runtime thread.
    @Test func theLiveCensusSeesARuntimeThread() async {
        let gate = DispatchSemaphore(value: 0)
        defer { gate.signal() }
        await withCheckedContinuation { (started: CheckedContinuation<Void, Never>) in
            let thread = Thread {
                started.resume()
                gate.blockingWait()
            }
            thread.name = "tokio-runtime-worker"
            thread.start()
        }

        let census = LaunchThreadCensus.now()

        #expect(census.threads > 1)
        #expect(census.runtimeThreads >= 1)
    }
}
#endif
