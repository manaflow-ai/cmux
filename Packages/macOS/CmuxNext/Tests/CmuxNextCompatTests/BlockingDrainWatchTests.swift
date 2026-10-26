#if DEBUG || CMUX_BLOCKING_CHECKS
@testable import CmuxNextCompat
import Foundation
import Testing

/// The blocking detector's drain runs inside the watch the composition root installs (a hang-watch scope
/// on the `blocking-drain` lane, p09-observability-070), so a sink that hangs the drain is reported. Compat
/// sits below the hang watch, so the watch is a closure here.
@Suite(.serialized)
struct BlockingDrainWatchTests {
    @MainActor @Test func eachDrainPassRunsInsideTheInstalledWatch() async {
        let table = BlockingViolationTable(mode: .record)
        let detector = BlockingDetector(table: table)
        let probe = DrainProbe()
        detector.install(sink: probe)
        detector.watchDrain { drain in
            probe.enter()
            drain()
            probe.leave()
        }
        await BlockingViolationTable.$scoped.withValue(table) {
            _ = FileManager.checked.fileExists(atPath: "/")
        }
        await table.flush()

        #expect(probe.recordedInsideWatch == [true])
        #expect(probe.passes >= 1)
        #expect(probe.isInside == false)
    }

    @MainActor @Test func withNoWatchTheDrainStillRecords() async {
        let table = BlockingViolationTable(mode: .record)
        let detector = BlockingDetector(table: table)
        let probe = DrainProbe()
        detector.install(sink: probe)
        await BlockingViolationTable.$scoped.withValue(table) {
            _ = FileManager.checked.fileExists(atPath: "/")
        }
        await table.flush()

        #expect(probe.recordedInsideWatch == [false])
        #expect(probe.passes == 0)
    }

    @MainActor @Test func removingTheWatchStopsUsingIt() async {
        let table = BlockingViolationTable(mode: .record)
        let detector = BlockingDetector(table: table)
        let probe = DrainProbe()
        detector.watchDrain { drain in
            probe.enter()
            drain()
            probe.leave()
        }
        detector.watchDrain(nil)
        detector.install(sink: probe)
        await BlockingViolationTable.$scoped.withValue(table) {
            _ = FileManager.checked.fileExists(atPath: "/")
        }
        await table.flush()

        #expect(probe.recordedInsideWatch == [false])
        #expect(probe.passes == 0)
    }
}

/// Counts watched drain passes and notes, for each violation the sink gets, whether a pass was open.
private nonisolated final class DrainProbe: BlockingViolationSink {
    private struct State {
        var inside = false
        var passes = 0
        var recorded: [Bool] = []
    }

    private let state = Mutex(State())

    var passes: Int { state.withLock { $0.passes } }
    var isInside: Bool { state.withLock { $0.inside } }
    var recordedInsideWatch: [Bool] { state.withLock { $0.recorded } }

    func enter() {
        state.withLock {
            $0.inside = true
            $0.passes += 1
        }
    }

    func leave() {
        state.withLock { $0.inside = false }
    }

    func record(_ violation: BlockingViolation) {
        state.withLock { $0.recorded.append($0.inside) }
    }
}
#endif
