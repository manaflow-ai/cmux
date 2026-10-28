#if DEBUG
import AppKit
@testable import CmuxNextApp
import CmuxNextControl
import Testing

/// The notices the app's `debug.simulate.*` posts (p02-threads 307): AppKit's own, in the order macOS posts them, so
/// lifecycle-sweep.py's sleep, wake and display steps run the observers a real lid close or display change runs.
@Suite
struct LifecycleSimulationNoticesTests {
    @Test func theAppPostsAppKitsSleepWakeAndDisplayNoticesInMacOSsOrder() {
        let notices = LifecycleSimulationControl.Notices.appKit
        #expect(notices.sleep == [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification])
        #expect(notices.wake == [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification])
        #expect(notices.display == NSApplication.didChangeScreenParametersNotification)
    }
}
#endif
