import CmuxNextCompat
import CmuxNextMetrics
@testable import CmuxNextSignposts
@testable import CmuxNextTrace
import Testing

/// The five `launch.*` slices (p09-observability task 034): each milestone mark ends one, every slice begins at
/// the process start, and the ones reached before the temperature wait for it.
struct LaunchSlicesTests {
    /// What a test's escaping closures record, from any thread.
    nonisolated private final class Recorded<Element: Sendable>: Sendable {
        private let items = Mutex<[Element]>([])
        func append(_ item: Element) { items.withLock { $0.append(item) } }
        var all: [Element] { items.withLock { $0 } }
    }

    private static let start: UInt64 = 1_000

    /// The five reserved launch names each end at one milestone, as async slices of the launch category.
    @Test func everyLaunchSliceNameHasAMilestone() {
        let milestoneNames = LaunchSlices.Milestone.allCases.map(\.name)
        #expect(Set(milestoneNames) == [.launchProcessToMain, .launchFirstWindow, .launchFirstFrame, .launchDaemonReady,
                                        .launchFirstTerminalOutput])
        #expect(milestoneNames.allSatisfy { $0.traceCategory == .launch && !$0.opensThreadSlice })
    }

    nonisolated private static let milestoneCases: [(String, LaunchSlices.Milestone)] = [
        ("main_start", .processToMain), ("first_window_presented", .firstWindow),
        ("first_window_frame_committed", .firstFrame), ("daemon.handshake_end", .daemonReady),
        ("first_terminal_content", .firstTerminalOutput),
    ]

    @Test(arguments: milestoneCases)
    func milestoneMarks(mark: String, milestone: LaunchSlices.Milestone) {
        #expect(LaunchSlices.Milestone(mark: mark) == milestone)
    }

    @Test func otherMarksAreNoMilestone() {
        for mark in ["main.run", "dfl.windows", LaunchSlices.temperatureMark, "first_terminal_frame", ""] {
            #expect(LaunchSlices.Milestone(mark: mark) == nil, "\(mark)")
        }
    }

    /// Milestones before the temperature wait and come out, in order, with it; later ones come out at once.
    @Test func slicesWaitForTheTemperature() {
        var slices = LaunchSlices(processStartNanos: Self.start)
        #expect(slices.reach(.processToMain, atUptimeNanos: 2_000) == nil)
        #expect(slices.reach(.daemonReady, atUptimeNanos: 3_000) == nil)
        #expect(slices.temperature == nil)

        let waited = slices.sample(pageins: 4_000)
        #expect(waited == [
            LaunchSlices.Slice(name: .launchProcessToMain, beginNanos: Self.start, endNanos: 2_000, temperature: .cold),
            LaunchSlices.Slice(name: .launchDaemonReady, beginNanos: Self.start, endNanos: 3_000, temperature: .cold),
        ])
        #expect(slices.temperature == .cold)
        #expect(slices.pageins == 4_000)

        #expect(slices.reach(.firstFrame, atUptimeNanos: 9_000)
            == LaunchSlices.Slice(name: .launchFirstFrame, beginNanos: Self.start, endNanos: 9_000, temperature: .cold))
    }

    @Test func eachMilestoneAndTheSampleCountOnce() {
        var slices = LaunchSlices(processStartNanos: Self.start)
        #expect(slices.sample(pageins: 1).isEmpty)
        #expect(slices.reach(.firstWindow, atUptimeNanos: 5_000) != nil)
        #expect(slices.reach(.firstWindow, atUptimeNanos: 6_000) == nil)
        #expect(slices.sample(pageins: 9_999).isEmpty)
        #expect(slices.temperature == .warm)
        #expect(slices.pageins == 1)
    }

    @Test func unreadablePageinsStillReleaseTheSlices() {
        var slices = LaunchSlices(processStartNanos: Self.start)
        _ = slices.reach(.processToMain, atUptimeNanos: 2_000)
        #expect(slices.sample(pageins: nil).map(\.temperature) == [.undetermined])
        #expect(slices.pageins == nil)
    }

    /// A milestone before the converted start (a clock step) never gives a slice that ends before it begins.
    @Test func beginNeverPassesTheEnd() {
        var slices = LaunchSlices(processStartNanos: 5_000)
        _ = slices.sample(pageins: 10)
        #expect(slices.reach(.processToMain, atUptimeNanos: 4_000)?.beginNanos == 4_000)
    }

    /// A written slice is an estimated AB at the process start and an AE at the milestone whose `arg0` is the
    /// temperature code, both with the slice's id, under the launch category only.
    @Test func sliceWritesItsRecords() {
        let log = Recorded<TraceRuntime.StubRecord>()
        let runtime = TraceRuntime(role: .app, clock: TraceClock(), stubRecorder: { log.append($0) })
        let slice = LaunchSlices.Slice(name: .launchFirstFrame, beginNanos: 100, endNanos: 700, temperature: .lukewarm)
        #expect(!slice.record(into: runtime))

        runtime.setCategoryMask(1 << UInt64(SignpostCategory.launch.traceBit))
        #expect(slice.record(into: runtime))
        let name = SignpostName.launchFirstFrame.rawValue
        let bit = SignpostCategory.launch.traceBit
        #expect(log.all == [
            TraceRuntime.StubRecord(tNanos: 100, name: name, categoryBit: bit, phase: .asyncBegin,
                                    flags: [.asyncID, .estimated], arg0: 0, arg1: slice.asyncID),
            TraceRuntime.StubRecord(tNanos: 700, name: name, categoryBit: bit, phase: .asyncEnd, flags: .asyncID,
                                    arg0: 1, arg1: slice.asyncID),
        ])
    }

    @Test func eachNameHasItsOwnTrack() {
        let ids = Set(LaunchSlices.Milestone.allCases.map {
            LaunchSlices.Slice(name: $0.name, beginNanos: 0, endNanos: 0, temperature: .warm).asyncID
        })
        #expect(ids.count == 5)
    }

    /// A clock whose page-ins read `pageins` (`read` runs at each read).
    private static func clock(pageins: UInt64?, read: @escaping @Sendable () -> Void = {}) -> LaunchClock {
        LaunchClock(reader: LaunchClock.Reader(processStartWallNanos: { nil }, wallNanos: { 0 }, uptimeNanos: { 0 },
                                               pageins: { read(); return pageins }))
    }

    /// The marks in launch order through the mark path the app runs (read, apply under the lock, publish): only
    /// the temperature mark reads the page-ins; it releases the waiting slices in order with its temperature and
    /// the `launch.pageins` sample; a later milestone is written at once; a repeated temperature mark does nothing.
    @Test func launchMarksWriteTheirSlices() {
        let log = Recorded<TraceRuntime.StubRecord>()
        let runtime = TraceRuntime(role: .app, clock: TraceClock(), stubRecorder: { log.append($0) })
        runtime.setCategoryMask(1 << UInt64(SignpostCategory.launch.traceBit))
        let reads = Recorded<Int>()
        let clock = Self.clock(pageins: 120) { reads.append(1) }
        var slices = LaunchSlices(processStartNanos: Self.start)
        var steps: [LaunchSlices.Step] = []
        for (mark, at) in [("main_start", UInt64(2_000)), ("first_window_presented", 3_000), ("dfl.windows", 3_500),
                           (LaunchSlices.temperatureMark, 4_000), ("first_window_frame_committed", 5_000),
                           (LaunchSlices.temperatureMark, 6_000)] {
            let step = slices.apply(LaunchSlices.Reading(mark: mark, clock: clock), atUptimeNanos: at)
            step.publish(into: runtime)
            steps.append(step)
        }

        #expect(reads.all.count == 2)
        #expect(steps.map(\.slices.count) == [0, 0, 0, 2, 1, 0])
        #expect(steps.map(\.temperature) == [nil, nil, nil, .lukewarm, nil, nil])
        #expect(steps.map(\.pageinsSample) == [nil, nil, nil, 120, nil, nil])
        #expect(steps[3].temperatureInstant == "launch.temperature.lukewarm")
        #expect(steps.compactMap(\.temperatureInstant).count == 1)

        let bit = SignpostCategory.launch.traceBit
        func records(_ name: SignpostName, end: UInt64) -> [TraceRuntime.StubRecord] {
            let id = LaunchSlices.Slice(name: name, beginNanos: 0, endNanos: 0, temperature: .warm).asyncID
            return [
                TraceRuntime.StubRecord(tNanos: Self.start, name: name.rawValue, categoryBit: bit, phase: .asyncBegin,
                                        flags: [.asyncID, .estimated], arg0: 0, arg1: id),
                TraceRuntime.StubRecord(tNanos: end, name: name.rawValue, categoryBit: bit, phase: .asyncEnd, flags: .asyncID,
                                        arg0: UInt64(LaunchClock.Temperature.lukewarm.rawValue), arg1: id),
            ]
        }
        #expect(log.all == records(.launchProcessToMain, end: 2_000) + records(.launchFirstWindow, end: 3_000)
            + records(.launchFirstFrame, end: 5_000))
    }

    /// Unreadable page-ins still decide a temperature (undetermined, code 3) but record no `launch.pageins` sample.
    @Test func unreadablePageinsDecideUndeterminedWithoutASample() {
        let clock = Self.clock(pageins: nil)
        var slices = LaunchSlices(processStartNanos: Self.start)
        _ = slices.apply(LaunchSlices.Reading(mark: "main_start", clock: clock), atUptimeNanos: 2_000)
        let step = slices.apply(LaunchSlices.Reading(mark: LaunchSlices.temperatureMark, clock: clock), atUptimeNanos: 3_000)
        #expect(step.temperature == .undetermined)
        #expect(step.slices.map(\.temperature.rawValue) == [3])
        #expect(step.pageinsSample == nil)
        #expect(step.temperatureInstant == "launch.temperature.undetermined")
    }

    // MARK: launch.first_frame.<temperature> (task 058)

    /// A runtime with a fresh metrics store of the launch histograms attached, and that store.
    private static func runtimeWithStore() -> (TraceRuntime, MetricsStore) {
        let runtime = TraceRuntime(role: .app)
        let profile = MetricsProfile(appVersion: "1.0", buildNumber: "1", channel: "test", osVersion: "26.0", hardwareClass: "Mac16,10",
                                     bootSessionUUID: Array(0 ..< 16), buildUUID: Array(16 ..< 32),
                                     buildDay: MetricsProfile.Day(year: 2026, month: 10, day: 26))
        let catalog = HistogramID.LaunchTemperature.allCases.map(HistogramID.launchFirstFrame) + [.launchPageins]
        let store = MetricsStore(role: .app, profile: profile, pid: 4242, catalog: catalog)
        #expect(store.attach(to: runtime))
        return (runtime, store)
    }

    /// The histograms of `store` that have samples, by name: (count, sum).
    private static func recorded(in store: MetricsStore) -> [String: [UInt64]] {
        Dictionary(uniqueKeysWithValues: store.delta().histograms.map { ($0.name, [$0.count, $0.sum]) })
    }

    /// Runs `marks` (name, uptime) through the app's mark path (read, apply, publish) into `runtime`.
    private static func runMarks(_ marks: [(String, UInt64)], pageins: UInt64?, start: UInt64, into runtime: TraceRuntime) {
        let clock = Self.clock(pageins: pageins)
        var slices = LaunchSlices(processStartNanos: start)
        for (mark, at) in marks {
            slices.apply(LaunchSlices.Reading(mark: mark, clock: clock), atUptimeNanos: at).publish(into: runtime)
        }
    }

    private static let launchStart: UInt64 = 50_000_000_000

    /// The first committed frame records one sample, the process start to that frame in ms, in the histogram of
    /// the launch's temperature; a repeated first-frame mark records nothing more.
    @Test(arguments: [(UInt64(2), "launch.first_frame.warm"), (120, "launch.first_frame.lukewarm"),
                      (3_500, "launch.first_frame.cold")])
    func firstFrameRecordsPerTemperature(pageins: UInt64, histogram: String) {
        let (runtime, store) = Self.runtimeWithStore()
        let start = Self.launchStart
        Self.runMarks([("main_start", start + 40_000_000), (LaunchSlices.temperatureMark, start + 300_000_000),
                       ("first_window_frame_committed", start + 840_000_000),
                       ("first_window_frame_committed", start + 2_000_000_000)],
                      pageins: pageins, start: start, into: runtime)
        #expect(Self.recorded(in: store) == [histogram: [1, 840], "launch.pageins": [1, pageins]])
    }

    /// A first frame committed before the temperature mark waits for it, then records with that temperature.
    @Test func aFirstFrameBeforeTheTemperatureRecordsWhenItIsDecided() {
        let (runtime, store) = Self.runtimeWithStore()
        let start = Self.launchStart
        let clock = Self.clock(pageins: 9_000)
        var slices = LaunchSlices(processStartNanos: start)
        let frame = slices.apply(LaunchSlices.Reading(mark: "first_window_frame_committed", clock: clock),
                                 atUptimeNanos: start + 610_000_000)
        frame.publish(into: runtime)
        #expect(frame.firstFrameSample == nil)
        #expect(Self.recorded(in: store).isEmpty, "no temperature yet")

        let decided = slices.apply(LaunchSlices.Reading(mark: LaunchSlices.temperatureMark, clock: clock),
                                   atUptimeNanos: start + 700_000_000)
        #expect(decided.firstFrameSample?.temperature == .cold)
        #expect(decided.firstFrameSample?.duration == .milliseconds(610))
        decided.publish(into: runtime)
        #expect(Self.recorded(in: store) == ["launch.first_frame.cold": [1, 610], "launch.pageins": [1, 9_000]])
    }

    /// An undetermined launch (unreadable page-ins) records no first-frame sample, as Chrome records no
    /// temperature-split sample for one; marks that release no first-frame slice record none either.
    @Test func anUndeterminedLaunchRecordsNoFirstFrame() {
        let (runtime, store) = Self.runtimeWithStore()
        let start = Self.launchStart
        Self.runMarks([(LaunchSlices.temperatureMark, start + 300_000_000), ("first_window_presented", start + 500_000_000),
                       ("first_window_frame_committed", start + 840_000_000)],
                      pageins: nil, start: start, into: runtime)
        #expect(Self.recorded(in: store).isEmpty)
        #expect(LaunchSlices.Step().firstFrameSample == nil)
    }

    /// A hidden or windowless launch (the interrupted mark, sent before the first window) records no first-frame
    /// sample, whether its frame comes before or after the temperature, as Chrome's `ShouldLogStartupHistogram`
    /// records no startup duration for an interrupted launch. The first-frame slice still goes to the trace, and
    /// `launch.pageins` is still recorded.
    @Test(arguments: [false, true])
    func anInterruptedLaunchRecordsNoFirstFrame(frameBeforeTemperature: Bool) {
        let (runtime, store) = Self.runtimeWithStore()
        let start = Self.launchStart
        let clock = Self.clock(pageins: 2)
        let frame = ("first_window_frame_committed", start + 240_000_000_000) // the window opened 4 min later
        let temperature = (LaunchSlices.temperatureMark, start + 300_000_000)
        let marks = [("main_start", start + 40_000_000), (LaunchSlices.interruptedMark, start + 200_000_000)]
            + (frameBeforeTemperature ? [frame, temperature] : [temperature, frame])
        var slices = LaunchSlices(processStartNanos: start)
        var released: [LaunchSlices.Slice] = []
        for (mark, at) in marks {
            let step = slices.apply(LaunchSlices.Reading(mark: mark, clock: clock), atUptimeNanos: at)
            #expect(step.firstFrameSample == nil, "\(mark)")
            step.publish(into: runtime)
            released += step.slices
        }
        #expect(Self.recorded(in: store) == ["launch.pageins": [1, 2]])
        #expect(released.filter { $0.name == .launchFirstFrame }
            == [LaunchSlices.Slice(name: .launchFirstFrame, beginNanos: start, endNanos: frame.1, temperature: .warm)])
    }

    /// Only the interrupted mark interrupts, and it is no milestone; a launch is not interrupted before it comes.
    @Test func onlyTheInterruptedMarkInterrupts() {
        let clock = Self.clock(pageins: 2)
        let interrupting = LaunchSlices.Reading(mark: LaunchSlices.interruptedMark, clock: clock)
        #expect(interrupting.interrupts)
        #expect(interrupting.milestone == nil)
        for mark in ["main_start", LaunchSlices.temperatureMark, "first_window_frame_committed", "launch.temperature.warm"] {
            #expect(!LaunchSlices.Reading(mark: mark, clock: clock).interrupts, "\(mark)")
        }
        var slices = LaunchSlices(processStartNanos: Self.start)
        #expect(!slices.apply(LaunchSlices.Reading(mark: "main_start", clock: clock), atUptimeNanos: 2_000).interrupted)
        #expect(!slices.interrupted)
        #expect(slices.apply(interrupting, atUptimeNanos: 3_000).interrupted)
        #expect(slices.apply(LaunchSlices.Reading(mark: LaunchSlices.temperatureMark, clock: clock), atUptimeNanos: 4_000).interrupted)
        #expect(slices.interrupted)
    }
}
