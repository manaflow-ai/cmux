import AppKit
@testable import CmuxNextApp
@testable import CmuxNextDesign
import CmuxNextLayout
import CmuxNextTestSupport
import Testing

/// Review of #40387 (follow-up): the live-resize tracker must observe before the first main window
/// can enter full screen, not from the first per-window motion read, or a transition that starts
/// before that read is missed for its whole length. The app starts it when it makes a main window
/// (`WindowManager.makeController` asks `Motion.panes.windowOpenBehavior(restoring:)`, which calls
/// `Motion.startLiveResizeTracking()`). This guards that start: a change of that line that drops
/// the call fails here.
@MainActor @Suite(.serialized, .closesItsWindows) struct LiveResizeTrackingStartTests {
    @Test func makingAMainWindowStartsTheLiveResizeTracker() {
        _ = NSApplication.shared
        // A tracker that no one started, on a private center, in place of the app's.
        let app = LiveResizeWindows.shared
        let fresh = LiveResizeWindows(center: NotificationCenter())
        LiveResizeWindows.shared = fresh
        defer { LiveResizeWindows.shared = app }
        #expect(!fresh.startedByApp, "a tracker that only exists is not started")

        let services = AppServices(environment: AppEnvironment.current([:]))
        services.windows.ordersWindowsIn = false
        services.windows.registry.provisional["live-resize-start-window"] = ["k1"]
        let controller = services.windows.makeController(for: WindowRegistry.Window(id: "live-resize-start-window"))
        defer {
            controller.teardown()
            controller.window?.close()
        }
        #expect(fresh.startedByApp, "making a main window did not start the live-resize tracker")
        #expect(LiveResizeWindows.shared === fresh, "the start replaced the tracker")
    }

    @Test func aMotionReadAloneDoesNotCountAsTheAppsStart() {
        let app = LiveResizeWindows.shared
        let fresh = LiveResizeWindows(center: NotificationCenter())
        LiveResizeWindows.shared = fresh
        defer { LiveResizeWindows.shared = app }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.borderless], backing: .buffered, defer: true)
        defer { window.closeAfterTest() }
        _ = Motion.isLiveResizing(window)
        _ = Motion.panes.policy(in: window)
        #expect(!fresh.startedByApp, "the flag must tell the app's start from a read, or the test above proves nothing")
    }
}
