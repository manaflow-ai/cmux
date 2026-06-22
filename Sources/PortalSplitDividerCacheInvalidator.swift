import AppKit

final class PortalSplitDividerCacheInvalidator {
    private var observations: [NSKeyValueObservation] = []
    private var notificationObservers: [NSObjectProtocol] = []

    deinit {
        invalidate()
    }

    func observe(_ views: [NSView], onChange: @escaping () -> Void) {
        invalidate()
        notificationObservers = views.flatMap { view in
            view.postsFrameChangedNotifications = true
            view.postsBoundsChangedNotifications = true
            return [
                NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: view, queue: nil) { _ in onChange() },
                NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: view, queue: nil) { _ in onChange() },
            ]
        }
        observations = views.flatMap { view in
            [
                view.observe(\.isHidden, options: [.new]) { _, _ in onChange() },
                view.observe(\.subviews, options: [.new]) { _, _ in onChange() },
            ]
        }
    }

    func invalidate() {
        observations.removeAll()
        notificationObservers.forEach(NotificationCenter.default.removeObserver)
        notificationObservers.removeAll()
    }
}
