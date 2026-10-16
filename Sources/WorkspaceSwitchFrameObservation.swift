import Foundation

/// Owns one switch-time frame observer and its rendered-frame demand lease.
///
/// Cleanup is tied to this value's lifetime so coordinator deallocation cannot
/// strand either resource when no explicit window teardown callback arrives.
final class WorkspaceSwitchFrameObservation {
    private let notificationCenter: NotificationCenter
    private let observer: NSObjectProtocol
    private let releaseRenderedFrameNotifications: () -> Void

    init(
        notificationCenter: NotificationCenter,
        observer: NSObjectProtocol,
        releaseRenderedFrameNotifications: @escaping () -> Void
    ) {
        self.notificationCenter = notificationCenter
        self.observer = observer
        self.releaseRenderedFrameNotifications = releaseRenderedFrameNotifications
    }

    deinit {
        notificationCenter.removeObserver(observer)
        releaseRenderedFrameNotifications()
    }
}
