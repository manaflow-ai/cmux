import AppKit

@MainActor
final class PortalSplitDividerCacheInvalidator {
    private var observations: [NSKeyValueObservation] = []
    private var notificationObservers: [NSObjectProtocol] = []

    deinit {
        invalidate()
    }

    func observe(_ views: [NSView], onChange: @escaping @MainActor () -> Void) {
        invalidate()
        for view in views {
            // These NSView flags are shared; do not restore them per observer or
            // one portal cache can disable notifications another cache still needs.
            view.postsFrameChangedNotifications = true
            view.postsBoundsChangedNotifications = true
        }
        notificationObservers = views.flatMap { view in
            return [
                NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: view, queue: nil) { _ in
                    MainActor.assumeIsolated { onChange() }
                },
                NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: view, queue: nil) { _ in
                    MainActor.assumeIsolated { onChange() }
                },
            ]
        }
        observations = views.flatMap { view in
            [
                view.observe(\.isHidden, options: [.new]) { _, _ in
                    MainActor.assumeIsolated { onChange() }
                },
                view.observe(\.subviews, options: [.new]) { _, _ in
                    MainActor.assumeIsolated { onChange() }
                },
            ]
        }
    }

    func invalidate() {
        observations.removeAll()
        notificationObservers.forEach(NotificationCenter.default.removeObserver)
        notificationObservers.removeAll()
    }
}
