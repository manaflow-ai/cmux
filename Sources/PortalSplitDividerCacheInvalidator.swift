import AppKit

@MainActor
final class PortalSplitDividerCacheInvalidator {
    private var observations: [NSKeyValueObservation] = []
    private var notificationObservers: [NSObjectProtocol] = []
    private var notificationPostingRestorers: [@MainActor () -> Void] = []

    deinit {
        invalidate()
    }

    func observe(_ views: [NSView], onChange: @escaping @MainActor () -> Void) {
        invalidate()
        var restorers: [@MainActor () -> Void] = []
        for view in views {
            let postsFrameChangedNotifications = view.postsFrameChangedNotifications
            let postsBoundsChangedNotifications = view.postsBoundsChangedNotifications
            view.postsFrameChangedNotifications = true
            view.postsBoundsChangedNotifications = true
            restorers.append { [weak view] in
                view?.postsFrameChangedNotifications = postsFrameChangedNotifications
                view?.postsBoundsChangedNotifications = postsBoundsChangedNotifications
            }
        }
        notificationPostingRestorers = restorers
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
        notificationPostingRestorers.forEach { $0() }
        notificationPostingRestorers.removeAll()
    }
}
