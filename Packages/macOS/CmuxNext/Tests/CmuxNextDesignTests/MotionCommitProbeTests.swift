@testable import CmuxNextDesign
import Foundation
import Testing

/// `debug.motion` work `ca.commit` (MotionCommitProbe): the span of each Core Animation commit,
/// which holds Chromium's pre-commit wait for a page's frame at a new size (fork API 27). Review 2 of
/// PL-cef-layer slice 1: no bench measured that wait, so a resize sync that cost a frame per motion
/// frame could not be told from one that cost nothing.
@MainActor
@Suite(.serialized) struct MotionCommitProbeTests {
    final class FakeClock {
        var time: CFTimeInterval = 100
    }

    @Test func eachCommitIsRecordedInMilliseconds() {
        let clock = FakeClock()
        var recorded: [Double] = []
        let probe = MotionCommitProbe(now: { clock.time }) { recorded.append($0) }
        probe.commitWillStart()
        clock.time += 0.006
        probe.commitDidEnd()
        #expect(recorded.count == 1)
        #expect(abs((recorded.first ?? 0) - 6) < 0.001)
    }

    @Test func anEmptyPassAndAnEndWithoutAStartRecordNothing() {
        let clock = FakeClock()
        var recorded: [Double] = []
        let probe = MotionCommitProbe(now: { clock.time }) { recorded.append($0) }
        probe.commitDidEnd()
        probe.commitWillStart()
        clock.time += 0.00001
        probe.commitDidEnd()
        // The end consumed its start: a second end has nothing to pair with.
        clock.time += 0.01
        probe.commitDidEnd()
        #expect(recorded.isEmpty)
    }

    @Test func recordingAddsCommitsToTheMotionWorkReport() {
        MotionTrace.start()
        defer { MotionTrace.stop() }
        MotionTrace.record(MotionCommitProbe.workName, milliseconds: 7)
        #expect(MotionTrace.work[MotionCommitProbe.workName] == [7])
        MotionTrace.stop()
        MotionTrace.record(MotionCommitProbe.workName, milliseconds: 9)
        #expect(MotionTrace.work[MotionCommitProbe.workName] == [7])
    }

    /// Review 2: the probe was a static of `MotionTrace` (global run-loop observers on a package type). The
    /// `debug.motion` handler owns it now: `start` adds its observers, `stop` removes them, and a recording without
    /// one adds none.
    @Test func theDebugMotionHandlerStartsAndStopsItsOwnProbe() {
        let probe = MotionCommitProbe(record: { _ in })
        _ = MotionDebug.handle(["action": "start"], windows: [], commitProbe: probe)
        #expect(probe.isRunning)
        _ = MotionDebug.handle(["action": "read"], windows: [], commitProbe: probe)
        #expect(probe.isRunning)
        _ = MotionDebug.handle(["action": "stop"], windows: [], commitProbe: probe)
        #expect(!probe.isRunning)
        #expect(!MotionTrace.isEnabled)
    }

    /// `work`'s `each_ms`: the time of every frame in the order recorded, as many as `frames`. The summary beside it
    /// (p50, p95, max) cannot leave out a frame that the host disturbed; with the list a reader judges each frame
    /// against the host's clock. The list ends where the record does (`MotionTrace.record`'s bound for a name).
    @Test func theWorkReportListsEachFramesTimeInTheOrderRecorded() throws {
        _ = MotionDebug.handle(["action": "start"], windows: [])
        defer { _ = MotionDebug.handle(["action": "stop"], windows: []) }
        for time in [3.456, 0.5, 12.004, 0.5, 1.999] { MotionTrace.record("clock", milliseconds: time) }
        MotionTrace.record("other", milliseconds: 2)
        func work(_ name: String) throws -> (each: [Double]?, frames: Int?) {
            let report = MotionDebug.handle(["action": "read"], windows: [])
            let work = try #require(report["work"] as? [String: [String: Any]], "the report has no work summaries")
            let summary = try #require(work[name], "the report has no work summary of \(name): \(work.keys.sorted())")
            return (summary["each_ms"] as? [Double], summary["frames"] as? Int)
        }
        let clock = try work("clock")
        #expect(clock.each == [3.46, 0.5, 12.0, 0.5, 2.0],
                "the work summary of `clock` lists \(String(describing: clock.each)) as each frame's time (want the 5 recorded, in order, to 0.01 ms)")
        #expect(clock.each?.count == clock.frames, "each_ms has \(clock.each?.count ?? -1) times for \(clock.frames ?? -1) frames")
        #expect(try work("other").each == [2], "a second name's list is its own")

        // The bound: a name records `MotionTrace.capacity * 16` frames and no more, and the list is as long.
        let bound = MotionTrace.capacity * 16
        for _ in 0..<(bound + 10) { MotionTrace.record("full", milliseconds: 1) }
        let full = try work("full")
        #expect(full.frames == bound, "a name recorded \(full.frames ?? -1) frames (its bound is \(bound))")
        #expect(full.each?.count == bound, "each_ms has \(full.each?.count ?? -1) times at the bound of \(bound) frames")
    }
}
