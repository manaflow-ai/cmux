@testable import CmuxNextLaunch
import CmuxNextWakeups
import os
import Testing

/// The slow-launch ring (p08-startup-111): reports off makes none, it fits 32 KiB, a full ring overwrites its oldest
/// record, short slices are left out, and completion frees it (keeping the events only when asked) and takes the
/// producers' hooks off.
@Suite struct SlowLaunchRingTests {
    private typealias Ring = StartupTrace.SlowLaunchRing

    /// Process start at 1 ms on the trace clock; the calling thread is the main thread.
    private static func ring(bytes: Int = Ring.defaultBytes) -> Ring {
        Ring(processStartNanos: 1_000_000, bytes: bytes, mainThread: StartupTrace.threadID(), now: { 1_000_000 })
    }

    @Test func reportsOffMakesNoRingAndReadsNoClock() {
        var read = false
        let off = Ring.forReports(optedIn: false, processStartNanos: { read = true; return 5 }())
        #expect(off == nil)
        #expect(!read)
        let ring = Ring.forReports(optedIn: true, processStartNanos: 5)
        #expect(ring?.processStartNanos == 5)
        #expect(ring?.ringBytes ?? 0 > 0)
    }

    @Test func theRingFitsThirtyTwoKiB() {
        let ring = Self.ring()
        let stride = MemoryLayout<StartupTraceRecord>.stride
        #expect(Ring.defaultBytes == 32 * 1_024)
        #expect(ring.capacity == 32 * 1_024 / stride)
        #expect(ring.ringBytes <= 32 * 1_024)
        #expect(ring.heldBytes >= ring.ringBytes)
    }

    @Test func aFullRingOverwritesItsOldestRecordAndCountsIt() throws {
        let ring = Self.ring(bytes: 4 * MemoryLayout<StartupTraceRecord>.stride)
        #expect(ring.capacity == 4)
        for index in 0..<6 { ring.mark("m\(index)", at: 1_000_000 + UInt64(index) * 1_000) }
        #expect(ring.overwritten == 2)
        let launch = try #require(ring.finish(keeping: true))
        #expect(launch.overwritten == 2)
        #expect(launch.events.map(\.name) == ["m2", "m3", "m4", "m5"])
        #expect(launch.events.map(\.startMicros) == [2, 3, 4, 5])
    }

    @Test func slicesUnderOneMillisecondAreLeftOutAndMarksAreKept() throws {
        let ring = Self.ring()
        ring.mark("main_start", at: 1_500_000)
        ring.task("short", start: 2_000_000, end: 2_500_000)
        ring.task("AppServices.restore", start: 2_000_000, end: 6_000_000)
        ring.mainTurn(start: 3_000_000, end: 3_999_999)
        ring.mainTurn(start: 4_000_000, end: 9_000_000)
        ring.laneJobSink(.files, .userVisible, 5_000_000, 5_100_000)
        ring.laneJobSink(.files, .userVisible, 5_000_000, 8_000_000)
        let events = try #require(ring.finish(keeping: true)).events
        #expect(events == [
            Ring.Event(kind: .mark, name: "main_start", startMicros: 500, durationMicros: 0),
            Ring.Event(kind: .mainTask, name: "AppServices.restore", startMicros: 1_000, durationMicros: 4_000),
            Ring.Event(kind: .mainTurn, name: "main.turn", startMicros: 3_000, durationMicros: 5_000),
            Ring.Event(kind: .laneJob, name: "files.userVisible", startMicros: 4_000, durationMicros: 3_000),
        ])
    }

    @Test func aTaskOffTheMainThreadIsALaneTask() throws {
        let ring = Ring(processStartNanos: 0, bytes: Ring.defaultBytes, mainThread: nil, now: { 0 })
        ring.task("LaunchFileJobs.read", start: 0, end: 2_000_000)
        let events = try #require(ring.finish(keeping: true)).events
        #expect(events.map(\.kind) == [.laneTask])
    }

    /// Completion frees the ring at once (so it is gone well within completion + 1 s), runs the freed hooks once, and
    /// later records and a second completion do nothing.
    @Test func completionFreesTheRingRunsTheHooksAndStopsRecording() {
        let ring = Self.ring()
        let calls = OSAllocatedUnfairLock<[String]>(initialState: [])
        ring.whenFreed { calls.withLock { $0.append("before") } }
        ring.mark("main_start")
        #expect(ring.heldBytes > 0)
        #expect(ring.finish(keeping: false) == nil)
        #expect(ring.heldBytes == 0)
        #expect(calls.withLock { $0 } == ["before"])
        ring.mark("late")
        ring.mainTurn(start: 0, end: 5_000_000)
        #expect(ring.overwritten == 0)
        #expect(ring.finish(keeping: true) == nil)
        ring.whenFreed { calls.withLock { $0.append("after") } }
        #expect(calls.withLock { $0 } == ["before", "after"])
    }

    @Test func aKeptLaunchStillFreesTheRing() throws {
        let ring = Self.ring()
        ring.mark("first_window_frame_committed", at: 900_000_000)
        let launch = try #require(ring.finish(keeping: true))
        #expect(ring.heldBytes == 0)
        #expect(launch.events.map(\.name) == ["first_window_frame_committed"])
        #expect(launch.events.first?.startMicros == 899_000)
    }
}
