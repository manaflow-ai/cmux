import AppKit

@MainActor
final class PortalSplitDividerCacheInvalidator {
    private var observations: [NSKeyValueObservation] = []
    private var notificationObservers: [NSObjectProtocol] = []

    deinit {
        invalidate()
    }

    func observe(
        geometryViews: [NSView],
        structureViews: [NSView],
        onChange: @escaping @MainActor () -> Void
    ) {
        invalidate()
        let geometryViews = Self.uniqueViews(geometryViews)
        let subviewObservedViews = Self.uniqueViews(geometryViews + structureViews)

        for view in geometryViews {
            // These NSView flags are shared; do not restore them per observer or
            // one portal cache can disable notifications another cache still needs.
            view.postsFrameChangedNotifications = true
            view.postsBoundsChangedNotifications = true
        }
        notificationObservers = geometryViews.flatMap { view in
            return [
                NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: view, queue: nil) { _ in
                    MainActor.assumeIsolated { onChange() }
                },
                NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: view, queue: nil) { _ in
                    MainActor.assumeIsolated { onChange() }
                },
            ]
        }
        observations = geometryViews.map { view in
            view.observe(\.isHidden, options: [.new]) { _, _ in
                MainActor.assumeIsolated { onChange() }
            }
        }
        // Nested splits can be inserted under an existing container after cache
        // warm-up. Watch that structural edge without subscribing to descendant
        // frame/bounds churn.
        observations.append(contentsOf: subviewObservedViews.map { view in
            view.observe(\.subviews, options: [.new]) { _, _ in
                MainActor.assumeIsolated { onChange() }
            }
        })
    }

    private static func uniqueViews(_ views: [NSView]) -> [NSView] {
        var uniqueViews: [NSView] = []
        var ids = Set<ObjectIdentifier>()
        for view in views where ids.insert(ObjectIdentifier(view)).inserted {
            uniqueViews.append(view)
        }
        return uniqueViews
    }

    func invalidate() {
        observations.removeAll()
        notificationObservers.forEach(NotificationCenter.default.removeObserver)
        notificationObservers.removeAll()
    }
}
