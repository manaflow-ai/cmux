import CmuxNextCompat
import CmuxNextLaunch
@testable import CmuxNextSignposts
@testable import CmuxNextTrace
import CmuxNextWakeups
import CmuxNextWakeupsTestSupport
import Testing

/// A launch read's completion event: steps that need the read run on its signal, in
/// post order, once; a step posted later runs at once. The browser follows that no engine reads are
/// afterFirstFrame posts.
@MainActor @Suite(.timeLimit(.minutes(1))) struct LaunchReadEventTests {
    @Test func stepsWaitForTheSignalThenRunInPostOrderOnce() {
        let read = LaunchReadEvent("BrowserProfiles.loaded"), ran = ReadRan()
        read.post { ran.names.append("a") }
        read.post { ran.names.append("b") }
        #expect(ran.names.isEmpty, "a step ran before the read was done")
        #expect(read.waitingCount == 2)
        read.signal()
        #expect(ran.names == ["a", "b"])
        #expect(read.waitingCount == 0)
        read.signal()
        #expect(ran.names == ["a", "b"], "a second signal ran a step again")
    }

    /// The signal is the catalog's `launch.read_done` instant on the launch category, with
    /// the steps it released in arg0; a second signal records nothing.
    @Test func theSignalIsOneLaunchReadDoneEventWithTheStepsReleased() {
        let log = TraceLog()
        let runtime = TraceRuntime(role: .app, clock: TraceClock(), stubRecorder: { record in log.append(record) })
        runtime.setCategoryMask(1 << UInt64(SignpostCategory.launch.traceBit))
        let read = LaunchReadEvent("BrowserProfiles.loaded", signposter: Signposter(category: .launch, trace: runtime))
        read.post {}
        read.post {}
        read.signal()
        read.signal()
        let done = log.records.filter { $0.name == SignpostName.launchReadDone.rawValue }
        #expect(done.map(\.phase) == [.instant])
        #expect(done.map(\.arg0) == [2])
    }

    @Test func aStepPostedAfterTheSignalRunsAtOnce() {
        let read = LaunchReadEvent("BrowserProfiles.loaded"), ran = ReadRan()
        read.signal()
        read.post { ran.names.append("late") }
        #expect(ran.names == ["late"])
        #expect(read.isSignaled)
    }

    @Test func aStepPostedByAStepRunsInTheSameSignal() {
        let read = LaunchReadEvent("BrowserProfiles.loaded"), ran = ReadRan()
        read.post {
            ran.names.append("first")
            read.post { ran.names.append("nested") }
        }
        read.signal()
        #expect(ran.names == ["first", "nested"])
    }

    @Test func theBrowserFollowsRunAfterTheFirstFrameOnePostEach() {
        let s = StartupTestScheduler(), ran = ReadRan()
        LaunchServicePosts.browserFollows(historyDaemonSync: { ran.names.append("history") },
                                          locationTrailScope: { ran.names.append("trail") }).post(on: s.startup)
        s.fire()
        #expect(ran.names.isEmpty, "a browser follow ran before the first frame")
        s.startup.firstFrameCommitted()
        for _ in 0..<3 { s.fire() }
        #expect(ran.names == ["history", "trail"])
        let records = s.startup.log.records
        #expect(records.map(\.name.description) == ["History.startDaemonSync", "LocationTrail.watchScope"])
        #expect(records.allSatisfy { $0.priority == .afterFirstFrame && $0.destination == .main && $0.violation == nil })
    }
}

@MainActor
private final class ReadRan {
    var names: [String] = []
}

/// The records a test trace runtime wrote, from any thread.
nonisolated private final class TraceLog: Sendable {
    private let state = Mutex<[TraceRuntime.StubRecord]>([])

    var records: [TraceRuntime.StubRecord] { state.withLock { $0 } }

    func append(_ record: TraceRuntime.StubRecord) { state.withLock { $0.append(record) } }
}
