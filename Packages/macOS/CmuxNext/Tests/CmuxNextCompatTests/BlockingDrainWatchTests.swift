#if DEBUG || CMUX_BLOCKING_CHECKS
@testable import CmuxNextCompat
import Foundation
import Testing

/// Each job of the blocking detector's drain queue runs inside the watch the composition root sets (one
/// hang-watch scope on the `blocking.drain` lane), so a sink or a stack resolution
/// that hangs the drain is reported. Compat sits below the hang watch, so the watch is a closure here.
@Suite(.serialized)
struct BlockingDrainWatchTests {
    @MainActor @Test func aDrainedSiteReachesTheSinkInsideOneWatchedJob() async {
        let table = BlockingViolationTable(mode: .record)
        let detector = BlockingDetector(table: table)
        let probe = DrainProbe()
        detector.watchDrain { job in probe.run(job) }
        detector.install(sink: probe)
        await BlockingViolationTable.$scoped.withValue(table) {
            readRoot()
        }
        await table.flush()

        #expect(probe.recordedInside == [1])
        #expect(probe.jobs >= 1)
        #expect(probe.deepest == 1)
        #expect(probe.depth == 0)
    }

    @MainActor @Test func theReplayToANewSinkIsAWatchedJobToo() async {
        let table = BlockingViolationTable(mode: .record)
        let detector = BlockingDetector(table: table)
        await BlockingViolationTable.$scoped.withValue(table) {
            readRoot()
        }
        await table.flush() // drained with no sink and no watch: only published
        let probe = DrainProbe()
        detector.watchDrain { job in probe.run(job) }
        detector.install(sink: probe) // the replay
        await table.flush()

        #expect(probe.recordedInside == [1])
        #expect(probe.deepest == 1)
    }

    /// Watch and sink are drain-queue jobs that run in call order, so the composition root must set the watch
    /// first (WatchdogReporting.install does): a watch set after the sink misses that sink's replay.
    @MainActor @Test func aWatchSetAfterTheSinkMissesItsReplay() async {
        let table = BlockingViolationTable(mode: .record)
        let detector = BlockingDetector(table: table)
        await BlockingViolationTable.$scoped.withValue(table) {
            readRoot()
        }
        await table.flush()
        let probe = DrainProbe()
        detector.install(sink: probe) // the replay, queued before the watch
        detector.watchDrain { job in probe.run(job) }
        await table.flush()

        #expect(probe.recordedInside == [0])
        #expect(probe.jobs >= 1, "the flush after the watch is watched")
    }

    @MainActor @Test func withNoWatchTheDrainStillDelivers() async {
        let table = BlockingViolationTable(mode: .record)
        let detector = BlockingDetector(table: table)
        let probe = DrainProbe()
        detector.install(sink: probe)
        await BlockingViolationTable.$scoped.withValue(table) {
            readRoot()
        }
        await table.flush()

        #expect(probe.recordedInside == [0])
        #expect(probe.jobs == 0)
    }

    @MainActor @Test func aNilWatchStopsWatching() async {
        let table = BlockingViolationTable(mode: .record)
        let detector = BlockingDetector(table: table)
        let probe = DrainProbe()
        detector.watchDrain { job in probe.run(job) }
        detector.watchDrain(nil)
        detector.install(sink: probe)
        await BlockingViolationTable.$scoped.withValue(table) {
            readRoot()
        }
        await table.flush()

        #expect(probe.recordedInside == [0])
        #expect(probe.jobs == 0)
    }
}

/// One file-io call site, whoever calls it (the detector checks the thread when it runs).
private nonisolated func readRoot() {
    _ = FileManager.checked.fileExists(atPath: "/")
}

/// A drain watch and a sink at once: counts the watched jobs and their nesting, and notes for each violation the
/// sink gets how many watched jobs were open around it.
private nonisolated final class DrainProbe: BlockingViolationSink {
    private struct State {
        var depth = 0
        var deepest = 0
        var jobs = 0
        var recorded: [Int] = []
    }

    private let state = Mutex(State())

    var jobs: Int { state.withLock { $0.jobs } }
    var depth: Int { state.withLock { $0.depth } }
    var deepest: Int { state.withLock { $0.deepest } }
    var recordedInside: [Int] { state.withLock { $0.recorded } }

    func run(_ job: () -> Void) {
        state.withLock { state in
            state.depth += 1
            state.jobs += 1
            state.deepest = max(state.deepest, state.depth)
        }
        job()
        state.withLock { $0.depth -= 1 }
    }

    func record(_ violation: BlockingViolation) {
        state.withLock { state in
            let depth = state.depth
            state.recorded.append(depth)
        }
    }
}
#endif
