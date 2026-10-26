import CmuxNextCompat
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
}
