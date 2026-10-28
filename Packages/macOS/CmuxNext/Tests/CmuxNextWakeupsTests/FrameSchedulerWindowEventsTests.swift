import AppKit
@testable import CmuxNextWakeups
import Testing

/// p06-scheduler-340 (recipe R-notif): a window's frame scheduler hears its window close and change screen through
/// the window's one observer per notice (``WindowEvents``), as Chromium's NSWindow delegate tells the widget's
/// observers (components/remote_cocoa/app_shim/views_nswindow_delegate.mm). Before, the scheduler and its screen
/// family each added a NotificationCenter observer of their own per window.
@MainActor @Suite(.serialized) struct FrameSchedulerWindowEventsTests {
    @Test func aWindowSchedulerSubscribesToItsWindowsEventsAndLeavesOnClose() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100), styleMask: [.borderless],
                              backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let scheduler = FrameScheduler.forWindow(window)
        let events = WindowEvents.of(window)
        #expect(events.subscriberCount(NSWindow.willCloseNotification) == 1, "the scheduler does not hear its window close")
        #expect(events.subscriberCount(NSWindow.didChangeScreenNotification) == 1,
                "the scheduler's screen family does not hear its window change screen")

        window.close()
        #expect(scheduler.closeObserver == nil, "the close did not invalidate the window's scheduler")
        #expect(events.subscriberCount(NSWindow.willCloseNotification) == 0, "the closed window's scheduler kept its close subscription")
    }
}
