import CmuxNextCompat
@testable import CmuxNextTrace
import Darwin
import Testing

/// The launch clock (p09-observability task 034): the process start moved onto the trace clock, the page-in
/// temperature at Chrome's thresholds, and the whole async slices the `launch.*` names write.
struct LaunchClockTests {
    private static let second: UInt64 = 1_000_000_000
    private static let millisecond: UInt64 = 1_000_000

    /// A clock whose reads are fixed: the process started at `startWall`, now is `wall` and `uptime`.
    private static func fixed(startWall: UInt64?, wall: UInt64, uptime: UInt64, pageins: UInt64? = 0) -> LaunchClock {
        LaunchClock(reader: .init(processStartWallNanos: { startWall }, wallNanos: { wall }, uptimeNanos: { uptime },
                                  pageins: { pageins }))
    }

    // MARK: temperature

    @Test func thresholdsAreChromes() {
        #expect(LaunchClock.Temperature.warmPageinsBelow == 5)
        #expect(LaunchClock.Temperature.coldPageinsFrom == 3_500)
    }

    /// Each side of each threshold: warm below 5, cold from 3500, lukewarm between, undetermined unreadable.
    private static let thresholdCases: [(UInt64, LaunchClock.Temperature)] = [
        (0, .warm), (4, .warm), (5, .lukewarm), (6, .lukewarm), (3_499, .lukewarm), (3_500, .cold), (3_501, .cold),
        (.max, .cold),
    ]

    @Test(arguments: thresholdCases)
    func temperatureAtEachThreshold(pageins: UInt64, expected: LaunchClock.Temperature) {
        #expect(LaunchClock.Temperature(pageins: pageins) == expected)
    }

    @Test func unreadablePageinsAreUndetermined() {
        #expect(LaunchClock.Temperature(pageins: nil) == .undetermined)
    }

    /// The end record's codes are the catalog's: 0 warm, 1 lukewarm, 2 cold.
    @Test func temperatureCodesMatchTheCatalog() {
        #expect(LaunchClock.Temperature.warm.rawValue == 0)
        #expect(LaunchClock.Temperature.lukewarm.rawValue == 1)
        #expect(LaunchClock.Temperature.cold.rawValue == 2)
        #expect(LaunchClock.Temperature.undetermined.rawValue == 3)
    }

    @Test func pageinsGoThroughTheReader() {
        #expect(Self.fixed(startWall: nil, wall: 0, uptime: 0, pageins: 42).pageins() == 42)
        #expect(Self.fixed(startWall: nil, wall: 0, uptime: 0, pageins: nil).pageins() == nil)
    }

    // MARK: process start

    /// The start is now's uptime less how long ago the kernel's wall-clock start was.
    @Test func processStartIsNowLessItsAge() {
        let clock = Self.fixed(startWall: 1_000 * Self.second, wall: 1_002 * Self.second + 5, uptime: 50 * Self.second)
        #expect(clock.processStart() == LaunchClock.Instant(wallNanos: 1_000 * Self.second,
                                                            uptimeNanos: 48 * Self.second - 5))
    }

    @Test func processStartIsNilWhenTheKernelDoesNotAnswer() {
        #expect(Self.fixed(startWall: nil, wall: 1, uptime: 1).processStart() == nil)
    }

    /// A start after now (the wall clock was set back) is now; one before uptime 0 is 0.
    @Test func conversionClampsAtBothEnds() {
        let now = LaunchClock.Instant(wallNanos: 100 * Self.second, uptimeNanos: 10 * Self.second)
        #expect(LaunchClock.uptimeNanos(ofWallNanos: 101 * Self.second, pairedWith: now) == 10 * Self.second)
        #expect(LaunchClock.uptimeNanos(ofWallNanos: 100 * Self.second, pairedWith: now) == 10 * Self.second)
        #expect(LaunchClock.uptimeNanos(ofWallNanos: 80 * Self.second, pairedWith: now) == 0)
        #expect(LaunchClock.uptimeNanos(ofWallNanos: 95 * Self.second, pairedWith: now) == 5 * Self.second)
    }

    /// The live process start lies within 5 ms of the kernel's own uptime-clock start, `ri_proc_start_abstime`
    /// (`proc_pid_rusage`, Mach absolute time), and before now.
    @Test func liveProcessStartIsWithinFiveMillisecondsOfTheKernels() throws {
        let start = try #require(LaunchClock().processStart())
        var info = rusage_info_v4()
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0) }
        }
        try #require(status == 0)
        var timebase = mach_timebase_info_data_t()
        try #require(mach_timebase_info(&timebase) == KERN_SUCCESS)
        let kernelNanos = info.ri_proc_start_abstime * UInt64(timebase.numer) / UInt64(timebase.denom)
        let difference = start.uptimeNanos > kernelNanos ? start.uptimeNanos - kernelNanos : kernelNanos - start.uptimeNanos
        #expect(difference < 5 * Self.millisecond, "process start \(start.uptimeNanos) ns, kernel \(kernelNanos) ns")
        #expect(start.uptimeNanos <= clock_gettime_nsec_np(CLOCK_UPTIME_RAW))
    }

    @Test func livePageinsAreReadable() {
        #expect(LaunchClock().pageins() != nil)
    }

    // MARK: whole async slices

    /// A slice is an AB at its begin time and an AE at its end time with one id, the begin's flags plus the
    /// async-id flag, under the category flag; off, it writes nothing.
    @Test func asyncSliceWritesBothRecordsAtTheirTimes() {
        let log = Mutex<[TraceRuntime.StubRecord]>([])
        let runtime = TraceRuntime(role: .app, clock: TraceClock(), stubRecorder: { record in log.withLock { $0.append(record) } })
        #expect(!runtime.writeAsyncSlice(name: 38, categoryBit: 5, id: 7, beginNanos: 100, endNanos: 900))
        #expect(log.withLock { $0.isEmpty })

        runtime.setCategoryMask(1 << 5)
        #expect(runtime.writeAsyncSlice(name: 38, categoryBit: 5, id: 7, beginNanos: 100, endNanos: 900,
                                        beginFlags: .estimated, beginArg0: 3, endArg0: 2))
        let records = log.withLock { $0 }
        #expect(records == [
            TraceRuntime.StubRecord(tNanos: 100, name: 38, categoryBit: 5, phase: .asyncBegin,
                                    flags: [.asyncID, .estimated], arg0: 3, arg1: 7),
            TraceRuntime.StubRecord(tNanos: 900, name: 38, categoryBit: 5, phase: .asyncEnd, flags: .asyncID, arg0: 2, arg1: 7),
        ])
    }

    /// With a ring attached, the slice's records decode at the given times.
    @Test func asyncSliceLandsInTheRingAtItsTimes() throws {
        let runtime = TraceRuntime(role: .app)
        let ring = TraceRing(records: 256, role: .app)
        #expect(runtime.attach(ring))
        runtime.setCategoryMask(1 << 5)
        runtime.writeAsyncSlice(name: 38, categoryBit: 5, id: 7, beginNanos: 1_000, endNanos: 5_000, endArg0: 1)
        let records = ring.records().filter { $0.name == 38 }
        try #require(records.count == 2)
        #expect(records[0].phase == .asyncBegin && records[0].timestamp == 1_000 && records[0].arg1 == 7)
        #expect(records[1].phase == .asyncEnd && records[1].timestamp == 5_000 && records[1].arg0 == 1 && records[1].arg1 == 7)
    }
}
