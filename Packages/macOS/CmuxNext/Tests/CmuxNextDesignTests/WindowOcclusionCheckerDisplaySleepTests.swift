import AppKit
@testable import CmuxNextDesign
import CmuxNextWakeups
import Testing

/// pro-audits item 2: the occlusion checker's "the displays sleep" follows the displays, not a pair of
/// notices. A system sleep that starts while the displays sleep wakes with only
/// `NSWorkspace.didWakeNotification`, and a display plugged in or out while they sleep posts only
/// `NSApplication.didChangeScreenParametersNotification`: with no `screensDidWakeNotification`, every
/// window used to stay off screen (frames, terminals and pages stopped) until the next display wake.
/// The displays' state comes from a fake probe, so no test depends on the host's displays.
@MainActor @Suite struct WindowOcclusionCheckerDisplaySleepTests {
    /// What the displays' probe reads; the test says when they sleep.
    final class FakeDisplays {
        var asleep = false
    }

    /// One visible window on private centers, judged by a checker whose displays `displays` describes.
    /// Each test runs the pass with `checker.update()`, so the result never waits for a later turn.
    struct Rig {
        let window: NSWindow
        let center: NotificationCenter
        let workspaceCenter: NotificationCenter
        let displays: FakeDisplays
        let checker: WindowOcclusionChecker

        init(asleep: Bool = false) {
            _ = NSApplication.shared
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.borderless],
                                  backing: .buffered, defer: true)
            window.isReleasedWhenClosed = false
            let center = NotificationCenter(), workspaceCenter = NotificationCenter()
            let displays = FakeDisplays()
            displays.asleep = asleep
            self.window = window
            self.center = center
            self.workspaceCenter = workspaceCenter
            self.displays = displays
            checker = WindowOcclusionChecker(
                windows: { [window] }, orderedWindows: { [window] },
                facts: { WindowOcclusionFacts(id: ObjectIdentifier($0), frame: CGRect(x: 0, y: 0, width: 800, height: 600), isActive: true) },
                isAppHidden: { false }, drawsWhenOccluded: false, center: center,
                workspaceEvents: AppEvents(center: workspaceCenter), displaysAsleep: { displays.asleep },
                mainWork: MainWorkScheduler(budget: MainFrameBudget()))
        }

        /// Runs a pass now and says whether the window was judged off screen.
        func offScreen() -> Bool {
            checker.update()
            return checker.isOffScreen(window)
        }
    }

    @Test func aSystemWakeWithNoScreensWakeBringsTheWindowBack() {
        let rig = Rig()
        rig.checker.start()
        defer { rig.checker.stop() }
        #expect(!rig.offScreen())
        rig.displays.asleep = true
        rig.workspaceCenter.post(name: NSWorkspace.screensDidSleepNotification, object: nil)
        #expect(rig.offScreen())
        // The Mac woke with its displays still dark: still off screen.
        rig.workspaceCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
        #expect(rig.offScreen())
        rig.displays.asleep = false
        rig.workspaceCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
        #expect(!rig.offScreen(), "a wake with no screens-wake notice left the window off screen")
    }

    @Test func aDisplayChangeWhileTheDisplaysSleepReadsThem() {
        let rig = Rig()
        rig.checker.start()
        defer { rig.checker.stop() }
        rig.displays.asleep = true
        rig.workspaceCenter.post(name: NSWorkspace.screensDidSleepNotification, object: nil)
        rig.center.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        #expect(rig.offScreen(), "every display still sleeps")
        rig.displays.asleep = false
        rig.center.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        #expect(!rig.offScreen(), "a display that is awake after the change left the window off screen")
    }

    /// A checker started while the displays sleep (a launch in the dark) judges them asleep from its
    /// first pass. A screens-wake notice then brings the window back even while the probe still reads
    /// asleep: the notice is the newer fact (the read on the same turn may lag it).
    @Test func aCheckerStartedWhileTheDisplaysSleepJudgesThemAsleep() {
        let rig = Rig(asleep: true)
        rig.checker.start()
        defer { rig.checker.stop() }
        #expect(rig.offScreen(), "a launch during display sleep judged the window on screen")
        rig.workspaceCenter.post(name: NSWorkspace.screensDidWakeNotification, object: nil)
        #expect(!rig.offScreen())
    }
}
