import CmuxNextLaunch
import Testing

/// p01-process-152: after `kill -9` of the app the daemon kept every terminal, but the relaunch drew the terminal
/// frames the last quit saved (an earlier run's screens), then the live screens replaced them. With
/// `relaunchReattach` on, a launch after a run that ended with no quit drops those frames before any pane mounts
/// (TerminalLaunchFrameTests covers the discard itself).
@MainActor
struct RelaunchReattachTests {
    @Test func onlyARunThatEndedWithNoQuitLosesTheSavedFrames() {
        #expect(RelaunchReattach(previousRunEndedUnasked: false, enabled: true).keepsSavedFrames, "a quit saved them")
        #expect(!RelaunchReattach(previousRunEndedUnasked: true, enabled: true).keepsSavedFrames)
        #expect(RelaunchReattach(previousRunEndedUnasked: true, enabled: false).keepsSavedFrames, "the feature is off")
    }

    @Test func aLaunchAfterAKillDiscardsTheFramesAndMarksIt() {
        var discarded = 0, marks: [String] = []
        RelaunchReattach(previousRunEndedUnasked: true, enabled: true)
            .apply(discardSavedFrames: { discarded += 1 }, mark: { marks.append($0) })
        #expect(discarded == 1)
        #expect(marks == [RelaunchReattach.skippedFramesMark])
    }

    @Test func aLaunchAfterAQuitOrWithTheFeatureOffKeepsTheFrames() {
        var discarded = 0, marks: [String] = []
        RelaunchReattach(previousRunEndedUnasked: false, enabled: true)
            .apply(discardSavedFrames: { discarded += 1 }, mark: { marks.append($0) })
        RelaunchReattach(previousRunEndedUnasked: true, enabled: false)
            .apply(discardSavedFrames: { discarded += 1 }, mark: { marks.append($0) })
        #expect(discarded == 0)
        #expect(marks.isEmpty)
    }
}
