@testable import CmuxNextControl
import CmuxNextCompat
import CmuxNextMetrics
import CmuxNextTrace
import CoreFoundation
import Foundation
import Testing

/// `hang.thread_hung.<lane>`: each lane's hangs in the 30 s of active time they happen in, as
/// a rate per hour (each hang 120), one sample per lane that hung, recorded into a test's own store.
extension MainThreadWatchdogTests {
    /// A store for the field histograms, and the runtime that records into it.
    private static func threadHungStore() -> (TraceRuntime, MetricsStore) {
        let runtime = TraceRuntime(role: .app)
        let profile = MetricsProfile(appVersion: "1.0", buildNumber: "1", channel: "test", osVersion: "26.0", hardwareClass: "Mac16,10",
                                     bootSessionUUID: Array(0 ..< 16), buildUUID: Array(16 ..< 32),
                                     buildDay: MetricsProfile.Day(year: 2026, month: 10, day: 26))
        let store = MetricsStore(role: .app, profile: profile, pid: 4244,
                                 catalog: [HistogramID.hangOver250PerHour] + HistogramID.HangLane.allCases.map(HistogramID.hangThreadHung))
        #expect(store.attach(to: runtime))
        return (runtime, store)
    }

    private static func histogram(_ id: HistogramID, in store: MetricsStore) -> MetricsDelta.Histogram? {
        store.delta().histograms.first { $0.name == id.name }
    }

    /// Two terminal-output hangs and one background-work hang in one active interval: one sample each, 240 and 120;
    /// an interval with none records no lane sample (its `hang.over250.per_hour` sample counts the active time).
    @Test func countsEachLanesHangsPerActiveInterval() throws {
        let (runtime, store) = Self.threadHungStore()
        let metrics = MainThreadFieldMetrics(metrics: Metrics(runtime: runtime))
        let second: UInt64 = 1_000_000_000
        metrics.inputArrived(atNanos: 1 * second)
        metrics.threadHung(.terminalOutput, atNanos: 2 * second)
        metrics.threadHung(.terminalOutput, atNanos: 3 * second)
        metrics.threadHung(.backgroundWork, atNanos: 4 * second)
        for input: UInt64 in [11, 21] { metrics.inputArrived(atNanos: input * second) }
        #expect(Self.histogram(.hangThreadHung(.terminalOutput), in: store) == nil, "20 active seconds: the interval is open")
        metrics.inputArrived(atNanos: 31 * second)
        let terminal = try #require(Self.histogram(.hangThreadHung(.terminalOutput), in: store))
        #expect(terminal.count == 1)
        #expect(terminal.sum == 2 * 120)
        let background = try #require(Self.histogram(.hangThreadHung(.backgroundWork), in: store))
        #expect(background.count == 1)
        #expect(background.sum == 120)
        #expect(Self.histogram(.hangThreadHung(.daemonReader), in: store) == nil, "a lane that never hung records nothing")

        for input: UInt64 in [41, 51, 61] { metrics.inputArrived(atNanos: input * second) }
        #expect(Self.histogram(.hangOver250PerHour, in: store)?.count == 2, "two active intervals")
        #expect(Self.histogram(.hangThreadHung(.terminalOutput), in: store)?.count == 1, "the quiet interval adds no lane sample")
    }

    /// A hang over 5 minutes after the newest input is not active time and does not count; a quit records the open
    /// interval's lane hangs once.
    @Test func aHangWhileThePersonIsAwayDoesNotCount() throws {
        let (runtime, store) = Self.threadHungStore()
        let metrics = MainThreadFieldMetrics(metrics: Metrics(runtime: runtime))
        let second: UInt64 = 1_000_000_000
        metrics.threadHung(.control, atNanos: second)
        metrics.inputArrived(atNanos: 10 * second)
        metrics.threadHung(.control, atNanos: 10 * second + MainThreadFieldMetrics.inactivityNanos)
        metrics.recordOpenInterval()
        #expect(Self.histogram(.hangThreadHung(.control), in: store) == nil, "before any input, and 5 minutes after it")
        metrics.threadHung(.control, atNanos: 20 * second)
        metrics.recordOpenInterval()
        metrics.recordOpenInterval()
        let control = try #require(Self.histogram(.hangThreadHung(.control), in: store))
        #expect(control.count == 1, "the quit records the open interval once")
        #expect(control.sum == 120)
    }

    /// A lane's count saturates at 255 in one interval instead of carrying into the next lane's count.
    @Test func aLanesCountSaturatesWithoutTouchingTheNextLane() throws {
        let (runtime, store) = Self.threadHungStore()
        let metrics = MainThreadFieldMetrics(metrics: Metrics(runtime: runtime))
        metrics.inputArrived(atNanos: 1_000_000_000)
        for _ in 0 ..< 300 { metrics.threadHung(.main, atNanos: 1_000_000_000) }
        metrics.recordOpenInterval()
        #expect(Self.histogram(.hangThreadHung(.main), in: store)?.sum == 255 * 120)
        #expect(Self.histogram(.hangThreadHung(.daemonReader), in: store) == nil, "the next lane's byte")
    }

    #if DEBUG
    /// The watchdog counts a main-thread hang (2 s by default, 100 ms here) in `hang.thread_hung.main` when it
    /// reports it. The injected clock moves only inside the stall, and the stall ends only once the hang reached
    /// the sink, so host load can neither add a hang nor make the count miss this one.
    @MainActor
    @Test func aMainThreadHangCountsInTheMainLane() throws {
        let (runtime, store) = Self.threadHungStore()
        let clock = ManualUptime()
        let watchdog = MainThreadWatchdog(configuration: .init(threshold: .milliseconds(50), sampleStacks: false, logStalls: false,
                                                               hangThreshold: .milliseconds(100), hangAssertThreshold: nil),
                                          uptime: clock.read, fieldMetrics: MainThreadFieldMetrics(metrics: Metrics(runtime: runtime)))
        let hung = SampleSignal()
        watchdog.onHang = { _ in hung.fire() }
        let now = clock.read()
        watchdog.noteInputDispatch(eventTimestamp: Double(now) / 1_000_000_000, dispatchedNanos: now)
        watchdog.start()
        defer { watchdog.stop() }
        CFRunLoopPerformBlock(CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue) {
            stallForTestUntilSampled(clock: clock, by: .seconds(3), sampled: hung)
            CFRunLoopStop(CFRunLoopGetMain())
        }
        CFRunLoopWakeUp(CFRunLoopGetMain())
        CFRunLoopRunInMode(.defaultMode, 30, false)
        try #require(hung.hasFired, "the watchdog did not report the hang")
        watchdog.recordFieldMetricsAtQuit()
        let main = try #require(Self.histogram(.hangThreadHung(.main), in: store))
        #expect(main.count == 1)
        #expect(main.sum == 120)
    }
    #endif
}
