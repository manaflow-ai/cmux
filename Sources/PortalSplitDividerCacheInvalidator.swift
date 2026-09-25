import AppKit

@MainActor
final class PortalSplitDividerCacheInvalidator {
    private struct SubviewSnapshot {
        weak var view: NSView?
        let childIDs: [ObjectIdentifier]

    }

    private var subviewSnapshots: [SubviewSnapshot] = []
    // Observer tokens are assigned/cleared from main-thread AppKit paths. Swift
    // deinit is nonisolated, so the teardown helper needs nonisolated access
    // after all main-thread use has ceased.
    private nonisolated(unsafe) var observations: [NSKeyValueObservation] = []
    private nonisolated(unsafe) var notificationObservers: [NSObjectProtocol] = []

    deinit {
        invalidateObservations()
    }

    func observe(
        geometryViews: [NSView],
        structureViews: [NSView],
        onChange: @escaping @MainActor () -> Void
    ) {
        invalidate()
        let geometryViews = Self.uniqueViews(geometryViews)
        let subviewObservedViews = Self.uniqueViews(geometryViews + structureViews)
        subviewSnapshots = subviewObservedViews.map {
            SubviewSnapshot(view: $0, childIDs: $0.subviews.map(ObjectIdentifier.init))
        }

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
        // Nested splits can be inserted under known layout containers after cache
        // warm-up. Keep this bounded to root/direct/split-related containers, not
        // arbitrary descendants such as WebKit or terminal internals.
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
        invalidateObservations()
        subviewSnapshots.removeAll()
    }

    /// AppKit may change a container's subviews without delivering KVO. Check
    /// only the already-observed layout containers before reusing a pointer cache.
    func structureIsCurrent() -> Bool {
        for snapshot in subviewSnapshots {
            guard let view = snapshot.view else { return false }
            let children = view.subviews
            guard children.count == snapshot.childIDs.count,
                  zip(children, snapshot.childIDs).allSatisfy({ ObjectIdentifier($0.0) == $0.1 }) else {
                return false
            }
        }
        return true
    }

    private nonisolated func invalidateObservations() {
        observations.removeAll()
        notificationObservers.forEach(NotificationCenter.default.removeObserver)
        notificationObservers.removeAll()
    }
}
