import Testing
@testable import CmuxTerminal

@Suite
struct GhosttyMetalLayerProfilingTests {
    @Test
    func disabledProfilingSkipsPreDrawableStateReadAndReset() {
        var stateReadCount = 0
        var wakeReasonResetCount = 0

        let snapshot: Int? = readRendererProfilingStateIfRequested(false) {
            stateReadCount += 1
            wakeReasonResetCount += 1
            return 42
        }

        #expect(snapshot == nil)
        #expect(stateReadCount == 0)
        #expect(wakeReasonResetCount == 0)
    }

    @Test
    func enabledProfilingReadsAndResetsStateOnce() {
        var stateReadCount = 0
        var wakeReasonResetCount = 0

        let snapshot: Int? = readRendererProfilingStateIfRequested(true) {
            stateReadCount += 1
            wakeReasonResetCount += 1
            return 42
        }

        #expect(snapshot == 42)
        #expect(stateReadCount == 1)
        #expect(wakeReasonResetCount == 1)
    }
}
