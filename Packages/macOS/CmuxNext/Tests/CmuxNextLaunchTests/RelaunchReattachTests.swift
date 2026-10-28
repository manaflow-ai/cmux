import CmuxNextLaunch
import Testing

/// After `kill -9` of the app the daemon kept every terminal, but the relaunch drew the terminal
/// frames and the window picture the last quit saved (an earlier run's screens), then the live screens replaced them.
/// With `relaunchReattach` on, a launch after a run that ended with no quit in this boot drops both before any pane
/// mounts and runs the takeover steps (TerminalLaunchFrameTests covers the discard itself, WindowPictureLaunchRulesTests
/// the picture's refusal).
@MainActor
struct RelaunchReattachTests {
    @Test func onlyARunThatEndedWithNoQuitInThisBootLosesTheSavedScreens() {
        #expect(RelaunchReattach(previousEnd: .quit, enabled: true).keepsSavedScreens, "a quit saved them")
        #expect(!RelaunchReattach(previousEnd: .killed, enabled: true).keepsSavedScreens)
        #expect(!RelaunchReattach(previousEnd: .crashed, enabled: true).keepsSavedScreens)
        #expect(RelaunchReattach(previousEnd: .killed, enabled: false).keepsSavedScreens, "the feature is off")
    }

    /// After a reboot or power loss no daemon survived: nothing live comes soon, so the saved screens still show through
    /// the cold daemon start instead of a blank pane.
    @Test func aSystemShutdownKeepsTheSavedScreens() {
        let reattach = RelaunchReattach(previousEnd: .systemShutdown, enabled: true)
        #expect(!reattach.reattaches)
        #expect(reattach.keepsSavedScreens)
        var discarded = 0, marks: [String] = []
        reattach.apply(steps: .unavailable, discardSavedFrames: { discarded += 1 }, mark: { marks.append($0) })
        #expect(discarded == 0)
        #expect(marks.isEmpty)
    }

    @Test func aLaunchAfterAKillDiscardsTheFramesThenRunsTheStepsInOrder() {
        let events = StepEvents()
        RelaunchReattach(previousEnd: .killed, enabled: true)
            .apply(steps: events.steps, discardSavedFrames: { events.list.append("discard") }, mark: { events.list.append($0) })
        #expect(events.list == ["discard", RelaunchReattach.skippedFramesMark, "rings", RelaunchReattach.ringsMappingMark,
                           "host", RelaunchReattach.hostAdoptingMark])
    }

    /// A build without p01-process-131 and p01-process-150 says so in its marks, so a bench run never counts as complete.
    @Test func theStandInStepsMarkThemselvesUnavailable() {
        var marks: [String] = []
        RelaunchReattach(previousEnd: .crashed, enabled: true).apply(steps: .unavailable, discardSavedFrames: {}, mark: { marks.append($0) })
        #expect(marks == [RelaunchReattach.skippedFramesMark, RelaunchReattach.ringsUnavailableMark,
                          RelaunchReattach.hostUnavailableMark])
    }

    @Test func aLaunchAfterAQuitOrWithTheFeatureOffKeepsTheFramesAndRunsNoStep() {
        let events = StepEvents()
        RelaunchReattach(previousEnd: .quit, enabled: true)
            .apply(steps: events.steps, discardSavedFrames: { events.list.append("discard") }, mark: { events.list.append($0) })
        RelaunchReattach(previousEnd: .killed, enabled: false)
            .apply(steps: events.steps, discardSavedFrames: { events.list.append("discard") }, mark: { events.list.append($0) })
        #expect(events.list.isEmpty)
    }
}

/// What the launch did, in order, with steps that record themselves and start.
@MainActor
private final class StepEvents {
    var list: [String] = []

    var steps: RelaunchReattach.Steps {
        RelaunchReattach.Steps(mapTerminalRings: { [self] in
            list.append("rings")
            return .started
        }, adoptBrowserHost: { [self] in
            list.append("host")
            return .started
        })
    }
}
