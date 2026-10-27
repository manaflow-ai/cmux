import AppKit

/// Keeps a window's frame family (its ``FrameScheduler``, the scheduler's input stage and every
/// ``FrameClient`` on it) on the display the window is on: when the window changes screen, the
/// scheduler moves to the new display's link at once, not on the old display's stall deadline.
///
/// One per window, made with the window's scheduler (``FrameScheduler/forWindow(_:)``), and the only
/// `NSWindow.didChangeScreenNotification` subscriber in CmuxNextWakeups, on the window's one observer per notice
/// (``WindowEvents``). Chrome does the same:
/// `-[ViewsNSWindowDelegate windowDidChangeScreen:]` (components/remote_cocoa/app_shim/
/// views_nswindow_delegate.mm) tells the window's host its display changed, and the compositor's
/// begin-frame source moves to that display's link (`ExternalBeginFrameSourceMac::SetVSyncDisplayID`,
/// components/viz/service/frame_sinks/external_begin_frame_source_mac.cc).
///
/// ```swift
/// scheduler.screenFamily = WindowScreenFamily(window: window, scheduler: scheduler)
/// ```
@MainActor
final class WindowScreenFamily {
    private let observation: EventSubscription

    /// - Parameters:
    ///   - window: The window whose screen changes are followed (not retained).
    ///   - scheduler: The window's scheduler (not retained: the window keeps it alive).
    ///   - center: Where the window posts its notifications (tests pass their own); the window's ``WindowEvents``
    ///     observe it, so a window whose events were made first keeps theirs.
    init(window: NSWindow, scheduler: FrameScheduler, center: NotificationCenter = .default) {
        let events = WindowEvents.of(window, center: center)
        observation = events.subscribe(NSWindow.didChangeScreenNotification, owner: "FrameScheduler.screen") { [weak scheduler] in
            scheduler?.screenDidChange()
        }
    }
}
