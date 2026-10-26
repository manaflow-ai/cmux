import AppKit
import CmuxNextCompat

/// Keeps a window's frame family (its ``FrameScheduler``, the scheduler's input stage and every
/// ``FrameClient`` on it) on the display the window is on: when the window changes screen, the
/// scheduler moves to the new display's link at once, not on the old display's stall deadline.
///
/// One per window, made with the window's scheduler (``FrameScheduler/forWindow(_:)``), and the only
/// `NSWindow.didChangeScreenNotification` observer in CmuxNextWakeups. Chrome does the same:
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
    private let observation: MainActorObservation

    /// - Parameters:
    ///   - window: The window whose screen changes are followed (not retained).
    ///   - scheduler: The window's scheduler (not retained: the window keeps it alive).
    ///   - center: Where the window posts its notifications (tests pass their own).
    init(window: NSWindow, scheduler: FrameScheduler, center: NotificationCenter = .default) {
        let name = NSWindow.didChangeScreenNotification
        observation = MainActorObservation(name, object: window, center: center) { [weak scheduler] in
            scheduler?.screenDidChange()
        }
    }
}
