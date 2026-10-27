import AppKit
@testable import CmuxNextLaunch
import CmuxNextWakeups
import CmuxNextWakeupsTestSupport
import Testing

/// A launch that shows no window (p08-startup-095). Launched hidden, or every window closed or minimized: the
/// restore's facts decide at once, and the first-frame, launch-image and restore refs end with `noWindow`, so
/// startup completes on the next turn, never at the failsafe. With `CMUX_NEXT_NO_ACTIVATE=1` the windows go behind
/// other apps' windows: the occlusion read in the restore's turn is not the system's yet, so the pane refs run and
/// the system's occlusion notice (or the watch's bound) decides (`LaunchCoverWatch`). The saved picture's read in a
/// hidden launch is `WindowPictureFrontReadTests`'.
@MainActor @Suite(.timeLimit(.minutes(1))) struct LaunchNoWindowTests {
    @MainActor private final class Ran {
        var names: [String] = []
    }

    /// A launch whose windows went behind other apps': its sight as the test sets it.
    @MainActor private final class Screen {
        var shown: [LaunchWindowSight.Shown]
        var coming = 0

        init(_ shown: [LaunchWindowSight.Shown]) {
            self.shown = shown
        }

        var sight: LaunchWindowSight {
            LaunchWindowSight(appHidden: false, orderedBehind: LaunchWindowSight.ordersBehind(noActivate: true, testScreen: false),
                              coming: coming, shown: shown)
        }
    }

    /// The refs at the end of a no-activate restore whose window shows one loading pane, on a real scheduler, with
    /// the cover watch on the test's notification center.
    @MainActor private final class CoveredLaunch {
        let phase: StartupPhase
        let s: StartupTestScheduler
        let refs: VisiblePaneRefs
        let center = NotificationCenter()
        let windows: [NSWindow]
        let screen: Screen

        init(windows count: Int = 1, _ shown: LaunchWindowSight.Shown = LaunchNoWindowTests.covered) {
            _ = NSApplication.shared
            let phase = StartupPhase(clock: ManualClock(), ledger: WakeupLedger())
            let s = StartupTestScheduler(phase: phase)
            self.phase = phase
            self.s = s
            refs = VisiblePaneRefs(startup: s.startup, phase: phase,
                                   bound: DemandTimer(owner: "test.bound", clock: ManualClock(), ledger: WakeupLedger()))
            windows = (0..<count).map { _ in
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled],
                                      backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                return window
            }
            screen = Screen(Array(repeating: shown, count: count))
            phase.markDone(.firstSnapshot)
            s.startup.finishRegistration()
        }

        /// The restore ends as `VisiblePaneRefs.finishRestore(of:)` ends it for windows ordered behind.
        func finishRestore() {
            refs.restoreFinished {
                [VisiblePaneRefs.Window(id: "w", content: .workspace(onScreen: [.init(key: "a", state: .loading)], layoutPanes: 1))]
            }
            let screen = screen
            // The bound's deadline never fires by itself here: a test passes it with `boundPassed()`.
            refs.watchCover(of: windows, center: center, deadlines: MainDeadlineScheduler(work: .still()),
                            sight: { screen.sight }, startup: s.startup, images: LaunchImageHold(startup: s.startup))
        }

        /// The system reports `window`'s occlusion.
        func report(_ window: Int = 0) {
            center.post(name: NSWindow.didChangeOcclusionStateNotification, object: windows[window])
        }

        func close() {
            for window in windows { window.close() }
        }
    }

    static let visible = LaunchWindowSight.Shown(onScreen: true, unoccluded: true)
    static let covered = LaunchWindowSight.Shown(onScreen: true, unoccluded: false)

    @Test func aBackgroundLaunchCompletesWithNoWindow() {
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
        let sight = LaunchWindowSight(appHidden: true, orderedBehind: false, coming: 0, shown: [Self.visible])
        #expect(sight.verdict == .noWindow)

        refs.launchShowedNoWindow(startup: s.startup, images: images)
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

    /// The covered window's occlusion read in the restore's turn decides nothing: the pane refs run, and the
    /// system's report that it is covered ends them with `noWindow`.
    @Test func aCoveredNoActivateLaunchEndsWithNoWindowOnceTheSystemReportsIt() {
        let f = CoveredLaunch()
        defer { f.close() }
        #expect(f.screen.sight.verdict == .mayBeCovered)
        f.finishRestore()
        #expect(f.phase.phase == .launching, "decided from the occlusion read in the turn the window was ordered in")
        #expect(f.s.startup.heldRefs.contains("Startup.visiblePane"), "the pane refs run until the system reports")

        f.report()
        #expect(f.phase.revealCause == .noWindow, "revealed at once, not at the 1.5 s deadline")
        #expect(f.phase.settleCause == .references, "settled by its references, not the 10 s failsafe")
        #expect(f.s.startup.heldRefs.isEmpty)
        f.s.hand.drain()
        #expect(f.s.startup.completion?.reason == .noWindow)
        // A frame the covered window commits later changes nothing.
        f.s.startup.firstFrameCommitted()
        #expect(f.s.startup.completion?.reason == .noWindow)
    }

    /// The window read covered when the restore ended, then the system reported it visible: the person sees it,
    /// so startup goes on waiting for its frame and its pane and never completes as `noWindow`.
    @Test func aWindowUncoveredAfterTheRestoreDoesNotCompleteAsNoWindow() {
        let f = CoveredLaunch()
        defer { f.close() }
        f.finishRestore()
        f.screen.shown = [Self.visible]
        f.report()
        #expect(f.refs.cover?.isWatching == false, "the watch ends once a window shows")
        #expect(f.phase.phase == .launching)
        #expect(f.s.startup.heldRefs.contains("Startup.visiblePane"), "the visible pane still holds startup")
        f.screen.shown = [Self.covered]  // covered again: the decision was made, the pane refs follow the window
        f.report()
        #expect(f.phase.revealCause == nil)
        f.phase.noteFirstFrame()
        f.s.startup.firstFrameCommitted()
        #expect(f.phase.revealCause == .firstFrame)
        #expect(f.s.startup.completion == nil, "the visible pane holds startup until its content shows")
    }

    /// No occlusion notice came by the bound: the window is still covered, so the refs end with `noWindow`.
    @Test func theBoundDecidesWhenTheSystemPostsNoNotice() {
        let f = CoveredLaunch()
        defer { f.close() }
        f.finishRestore()
        #expect(f.phase.phase == .launching)
        f.refs.cover?.boundPassed()
        #expect(f.phase.revealCause == .noWindow)
        f.s.hand.drain()
        #expect(f.s.startup.completion?.reason == .noWindow)
    }

    /// Every launch window's occlusion must be reported (or the bound pass) before the launch counts as covered: a
    /// window not reported yet may still read its occlusion from before the system knew.
    @Test func everyWindowIsReportedBeforeTheLaunchCountsAsCovered() {
        let f = CoveredLaunch(windows: 2)
        defer { f.close() }
        f.finishRestore()
        f.report(0)
        #expect(f.refs.cover?.isWatching == true, "decided before the second window's occlusion was reported")
        #expect(f.phase.phase == .launching)
        f.report(1)
        #expect(f.phase.revealCause == .noWindow)
    }

    /// A window still coming at the bound (its content, its launch build) may show: the pane refs decide.
    @Test func aWindowStillComingAtTheBoundLeavesItToThePaneRefs() {
        let f = CoveredLaunch()
        defer { f.close() }
        f.screen.coming = 1
        f.finishRestore()
        f.report()
        #expect(f.refs.cover?.isWatching == true, "a window still coming is not reported covered")
        f.refs.cover?.boundPassed()
        #expect(f.refs.cover?.isWatching == false)
        #expect(f.phase.phase == .launching, "a launch with a window coming completed as noWindow")
        #expect(f.s.startup.heldRefs.contains("Startup.visiblePane"))
    }

    @Test func theVerdictReadsOnlyWhatThePersonCanSee() {
        func verdict(hidden: Bool = false, behind: Bool = false, coming: Int = 0,
                     _ shown: [LaunchWindowSight.Shown]) -> LaunchWindowSight.Verdict {
            LaunchWindowSight(appHidden: hidden, orderedBehind: behind, coming: coming, shown: shown).verdict
        }
        let minimized = LaunchWindowSight.Shown(onScreen: false, unoccluded: false)
        #expect(verdict([Self.visible]) == .shows)
        #expect(verdict([Self.covered]) == .shows, "a window ordered in front shows, whatever the occlusion says yet")
        #expect(verdict(behind: true, [Self.covered]) == .mayBeCovered, "behind other apps' windows only the system can tell")
        #expect(verdict(behind: true, [Self.covered, Self.visible]) == .shows, "one uncovered window is enough")
        #expect(verdict(behind: true, coming: 1, []) == .mayBeCovered)
        #expect(verdict([minimized]) == .noWindow)
        #expect(verdict(behind: true, [minimized]) == .noWindow)
        #expect(verdict([]) == .noWindow, "no window")
        #expect(verdict(coming: 1, []) == .shows, "a window waiting for its content or its launch build will show")
        #expect(verdict(hidden: true, coming: 1, [Self.visible]) == .noWindow, "nothing shows while the app is hidden")
        #expect(LaunchWindowSight.ordersBehind(noActivate: true, testScreen: false))
        #expect(!LaunchWindowSight.ordersBehind(noActivate: true, testScreen: true), "an agent's test screen shows the window")
        #expect(!LaunchWindowSight.ordersBehind(noActivate: false, testScreen: false))
    }
}
