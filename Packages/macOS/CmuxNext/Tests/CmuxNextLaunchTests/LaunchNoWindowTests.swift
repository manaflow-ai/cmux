import CmuxNextLaunch
import CmuxNextWakeups
import CmuxNextWakeupsTestSupport
import Testing

/// A launch that shows no window (p08-startup-095): launched hidden, or with `CMUX_NEXT_NO_ACTIVATE=1` behind other
/// apps' windows that cover it. Its restore ends the first-frame, launch-image and restore refs with `noWindow`, so
/// startup completes on the next turn, never at the failsafe, and the launch takes no saved picture.
@MainActor @Suite(.timeLimit(.minutes(1))) struct LaunchNoWindowTests {
    @MainActor private final class Ran {
        var names: [String] = []
    }

    @Test func aBackgroundLaunchCompletesWithNoWindowAndTakesNoPicture() {
        let phase = StartupPhase(clock: ManualClock(), ledger: WakeupLedger())
        let s = StartupTestScheduler(phase: phase)
        let ran = Ran()
        s.startup.post(.afterFirstFrame, "Updater.start", on: .main) { ran.names.append("Updater.start") }
        let refs = VisiblePaneRefs(startup: s.startup, phase: phase)
        let images = LaunchImageHold(startup: s.startup)
        let image = images.began()  // an agent pane's last frame, in the hidden window
        phase.noteLaunch(.hidden)  // AppDelegate: launched hidden (`open -j`)
        phase.markDone(.firstSnapshot)
        s.startup.finishRegistration()
        // The hidden launch's restore: its window is ordered in, but the app is hidden.
        let sight = LaunchWindowSight(appHidden: true, orderedBehind: false, coming: 0, shown: [.init(onScreen: true, unoccluded: true)])
        #expect(!sight.showsWindow)
        #expect(!LaunchWindowSight.showsPicture(appHidden: true), "a hidden launch reads no saved picture into its first frame")

        refs.restoreShowedNoWindow(startup: s.startup, images: images)
        #expect(phase.phase == .settled, "no first frame and no pane is waited for")
        #expect(s.startup.heldRefs.isEmpty)
        image.end(.visiblePaneLoadedIdle)  // its page painted
        let late = images.began()  // another image put up before the posted completion runs
        #expect(s.startup.heldRefs.isEmpty, "an image in a launch with no window holds nothing")
        s.hand.drain()
        #expect(s.startup.completion?.reason == .noWindow)
        s.fire()
        #expect(ran.names == ["Updater.start"], "the work held for the first frame runs")
        late.end(.visiblePaneTimedOut)
        #expect(s.startup.completion?.reason == .noWindow)
    }

    @Test func aNoActivateLaunchCoveredByOtherAppsRevealsWithoutAFrame() {
        let phase = StartupPhase(clock: ManualClock(), ledger: WakeupLedger())
        let s = StartupTestScheduler(phase: phase)
        let refs = VisiblePaneRefs(startup: s.startup, phase: phase)
        phase.markDone(.firstSnapshot)
        s.startup.finishRegistration()
        // `CMUX_NEXT_NO_ACTIVATE=1` without a test screen: the window went behind every app's, which cover it.
        let behind = LaunchWindowSight.ordersBehind(noActivate: true, testScreen: false)
        let sight = LaunchWindowSight(appHidden: false, orderedBehind: behind, coming: 0, shown: [.init(onScreen: true, unoccluded: false)])
        #expect(!sight.showsWindow)
        #expect(phase.phase == .launching, "a window launch waits for its frame until it knows none shows")

        refs.restoreShowedNoWindow(startup: s.startup, images: LaunchImageHold(startup: s.startup))
        #expect(phase.revealCause == .noWindow, "revealed at once, not at the 1.5 s deadline")
        #expect(phase.settleCause == .references, "settled by its references, not the 10 s failsafe")
        s.hand.drain()
        #expect(s.startup.completion?.reason == .noWindow)
        // A frame the hidden window commits later changes nothing.
        s.startup.firstFrameCommitted()
        #expect(s.startup.completion?.reason == .noWindow)
    }

    @Test func aWindowShowsWhenThePersonCanSeeIt() {
        func sight(hidden: Bool = false, behind: Bool = false, coming: Int = 0,
                   _ shown: [LaunchWindowSight.Shown]) -> Bool {
            LaunchWindowSight(appHidden: hidden, orderedBehind: behind, coming: coming, shown: shown).showsWindow
        }
        let visible = LaunchWindowSight.Shown(onScreen: true, unoccluded: true)
        let covered = LaunchWindowSight.Shown(onScreen: true, unoccluded: false)
        let minimized = LaunchWindowSight.Shown(onScreen: false, unoccluded: false)
        #expect(sight([visible]))
        #expect(sight([covered]), "a window ordered in front shows, whatever the occlusion says yet")
        #expect(!sight(behind: true, [covered]), "a window behind other apps' that cover it does not")
        #expect(sight(behind: true, [covered, visible]), "one uncovered window is enough")
        #expect(!sight([minimized]))
        #expect(!sight([]), "no window")
        #expect(sight(coming: 1, []), "a window waiting for its content or its launch build will show")
        #expect(!sight(hidden: true, coming: 1, [visible]), "nothing shows while the app is hidden")
        #expect(LaunchWindowSight.ordersBehind(noActivate: true, testScreen: false))
        #expect(!LaunchWindowSight.ordersBehind(noActivate: true, testScreen: true), "an agent's test screen shows the window")
        #expect(!LaunchWindowSight.ordersBehind(noActivate: false, testScreen: false))
        #expect(LaunchWindowSight.showsPicture(appHidden: false))
    }
}
