#if os(iOS)
import CoreGraphics
import Testing
@testable import CmuxMobileShellUI

@Suite struct WorkspaceListScrollSmoothnessTallyTests {
    @Test func onTimeFramesAreNotHitches() {
        var tally = WorkspaceListScrollSmoothnessTally()
        for frame in 0..<60 {
            let timestamp = Double(frame) / 60
            tally.recordFrame(timestamp: timestamp, targetTimestamp: timestamp + 1 / 60, listWorked: false)
        }
        #expect(tally.frames == 60)
        #expect(tally.hitchedFrames == 0)
        #expect(tally.hitchRatio == 0)
    }

    @Test func aLateFrameCountsItsLatenessAgainstScrollTime() {
        var tally = WorkspaceListScrollSmoothnessTally()
        tally.recordFrame(timestamp: 0, targetTimestamp: 0.010, listWorked: false)
        tally.recordFrame(timestamp: 0.010, targetTimestamp: 0.020, listWorked: false)
        // Promised at 0.020, shown at 0.050: 30 ms late.
        tally.recordFrame(timestamp: 0.050, targetTimestamp: 0.060, listWorked: true)
        tally.recordFrame(timestamp: 0.060, targetTimestamp: 0.070, listWorked: false)
        tally.recordFrame(timestamp: 1.0, targetTimestamp: 1.010, listWorked: false)

        #expect(tally.hitchedFrames == 2)
        #expect(tally.hitchedFramesWithListWork == 1)
        #expect(abs(tally.worstHitchSeconds - 0.93) < 1e-9)
        #expect(abs(tally.hitchSeconds - 0.96) < 1e-9)
        #expect(abs(tally.hitchRatio - 960) < 1e-6)
    }

    @Test func rowsThatMoveInContentAreShifts() {
        var tally = WorkspaceListScrollSmoothnessTally()
        #expect(tally.recordRows(["a": 0, "b": 92]).isEmpty)
        #expect(tally.recordRows(["a": 0, "b": 92, "c": 184]).isEmpty)
        let moved = tally.recordRows(["a": 92, "b": 92.2, "c": 184])
        #expect(moved.map(\.id) == ["a"])
        #expect(tally.rowShifts == 1)
    }
}
#endif
