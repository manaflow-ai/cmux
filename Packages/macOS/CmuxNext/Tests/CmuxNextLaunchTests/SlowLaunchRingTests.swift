import CmuxNextHangReports
@testable import CmuxNextLaunch
import CmuxNextWakeups
import CmuxNextWakeupsTestSupport
import Foundation
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

    // MARK: the report

    /// A forced slow launch: a warm launch whose first frame came at 640 ms, past the 180 ms budget. Its ring and the
    /// startup scheduler's tasks become the report's trace; the ring's overwritten records count as dropped.
    @Test func aForcedSlowLaunchsRingBecomesTheReportsTrace() throws {
        let record = try #require(LaunchAggregate.Record(marks: [
            ("launch.temperature.warm", 90), ("first_window_frame_committed", 640), ("startup_complete.visiblePaneLoadedIdle", 2_000),
            ("startup_complete", 2_000),
        ]))
        #expect(HangReport.LaunchTrace.exceedsBudget(record))
        let ring = Ring(processStartNanos: 0, bytes: 3 * MemoryLayout<StartupTraceRecord>.stride, mainThread: nil, now: { 0 })
        ring.mark("main_start", at: 1_000_000)
        ring.mainTurn(start: 2_000_000, end: 30_000_000)
        ring.laneJobSink(.files, .userVisible, 3_000_000, 9_000_000)
        ring.mark("first_window_frame_committed", at: 640_000_000)
        let launch = try #require(ring.finish(keeping: HangReport.LaunchTrace.exceedsBudget(record)))
        #expect(ring.heldBytes == 0)
        let trace = try #require(launch.trace(of: record, tasks: []))
        #expect(trace.firstFrameMs == 640)
        #expect(trace.budgetMs == 180)
        #expect(trace.dropped == 1)
        #expect(trace.events.map(\.kind) == [.mainTurn, .laneJob, .mark])
        #expect(trace.events.last?.name == "first_window_frame_committed")
        #expect(Ring.Event.Kind.allCases.map(\.reportKind) == [.mark, .mainTask, .laneTask, .mainTurn, .laneJob])
        // Within its budget: no trace.
        let quick = try #require(LaunchAggregate.Record(marks: [
            ("launch.temperature.warm", 90), ("first_window_frame_committed", 150), ("startup_complete.noVisiblePane", 400),
            ("startup_complete", 400),
        ]))
        #expect(launch.trace(of: quick, tasks: []) == nil)
    }

    /// The scheduler's tasks of 1 ms and more join the ring's events, a main task or a lane task by destination.
    @Test func theSchedulersTasksJoinTheRingsEvents() throws {
        typealias Slice = Ring.Launch.TaskSlice
        let tasks = [
            Slice(name: "AppServices.restore", onMain: true, startNanos: 1_000_000, durationNanos: 5_000_000),
            Slice(name: "Launch.read", onMain: false, startNanos: 6_000_000, durationNanos: 2_000_000),
            Slice(name: "Short", onMain: true, startNanos: 8_000_000, durationNanos: 100),
        ]
        let launch = try #require(Self.ring().finish(keeping: true))
        #expect(launch.events(adding: tasks) == [
            Ring.Event(kind: .mainTask, name: "AppServices.restore", startMicros: 0, durationMicros: 5_000),
            Ring.Event(kind: .laneTask, name: "Launch.read", startMicros: 5_000, durationMicros: 2_000),
        ])
    }

    // MARK: the recorders' fan-out

    /// Freeing the ring at completion leaves the developer trace's lane jobs and main turns recording, and the
    /// producers' hooks stay on until the trace stops too.
    @Test func freeingTheRingNeverStopsTheTracesRecords() {
        let trace = StartupTrace(configuration: StartupTraceConfiguration(
                                     file: FileManager.default.temporaryDirectory.appending(path: "ring-\(UUID().uuidString)/trace.json")),
                                 processStartNanos: 0, clock: ManualClock(), now: { 10 })
        let ring = Self.ring()
        let recorders = StartupTrace.LaunchRecorders(trace: trace, ring: ring)
        let stopped = OSAllocatedUnfairLock(initialState: 0)
        recorders.whenAllStopped { stopped.withLock { $0 += 1 } }
        let lanes = recorders.laneJobSink
        let turns = recorders.mainTurnSink
        lanes?(.files, .userVisible, 1_000_000, 5_000_000)
        turns?(1_000_000, 4_000_000)
        #expect(trace.status.pending == 2)
        #expect(ring.finish(keeping: false) == nil)
        #expect(ring.heldBytes == 0)
        #expect(stopped.withLock { $0 } == 0)
        lanes?(.files, .userVisible, 6_000_000, 9_000_000)
        turns?(6_000_000, 9_000_000)
        #expect(trace.status.pending == 4)
        #expect(ring.overwritten == 0)
    }

    @Test func theHooksComeOffWhenTheOnlyRecorderStops() throws {
        let ring = Self.ring()
        let recorders = StartupTrace.LaunchRecorders(trace: nil, ring: ring)
        let stopped = OSAllocatedUnfairLock(initialState: 0)
        recorders.whenAllStopped { stopped.withLock { $0 += 1 } }
        let lanes = try #require(recorders.laneJobSink)
        lanes(.files, .userVisible, 1_000_000, 5_000_000)
        #expect(stopped.withLock { $0 } == 0)
        let events = try #require(ring.finish(keeping: true)).events
        #expect(events.map(\.kind) == [.laneJob])
        #expect(stopped.withLock { $0 } == 1)
        ring.finish(keeping: false)
        #expect(stopped.withLock { $0 } == 1)
    }

    @Test func noRecorderMeansNoHookAndNothingToStop() {
        let recorders = StartupTrace.LaunchRecorders(trace: nil, ring: nil)
        #expect(recorders.isEmpty)
        #expect(recorders.laneJobSink == nil)
        #expect(recorders.mainTurnSink == nil)
        #expect(recorders.uptimeNanos == nil)
        let stopped = OSAllocatedUnfairLock(initialState: 0)
        recorders.whenAllStopped { stopped.withLock { $0 += 1 } }
        #expect(stopped.withLock { $0 } == 1)
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
