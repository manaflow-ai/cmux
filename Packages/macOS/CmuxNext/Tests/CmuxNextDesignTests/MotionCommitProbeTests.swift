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
}
