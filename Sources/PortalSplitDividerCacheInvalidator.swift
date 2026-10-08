import AppKit
import os

@MainActor
final class PortalSplitDividerCacheInvalidator {
    private final class FrameworkInvalidationState: @unchecked Sendable {
        let lock = OSAllocatedUnfairLock(initialState: false)
    }

    private struct SubviewSnapshot {
        weak var view: NSView?
        let childIDs: [ObjectIdentifier]

    }

    private var subviewSnapshots: [SubviewSnapshot] = []
    // AppKit can deliver KVO and frame notifications on a main-thread stack
    // that is not running Swift's MainActor executor. Record invalidation
    // synchronously so the next hit test cannot reuse stale geometry; the
    // lock only protects this one-bit callback handoff.
    private nonisolated let frameworkInvalidation = FrameworkInvalidationState()
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
        // Capture the shared state object instead of `self`. NotificationCenter
        // and KVO retain their callbacks until their tokens are removed; a self
        // capture would therefore keep this invalidator alive past teardown.
        let frameworkInvalidation = frameworkInvalidation
        notificationObservers = geometryViews.flatMap { view in
            return [
                NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: view, queue: nil) { _ in
                    frameworkInvalidation.lock.withLock { $0 = true }
                    Task { @MainActor in onChange() }
                },
                NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: view, queue: nil) { _ in
                    frameworkInvalidation.lock.withLock { $0 = true }
                    Task { @MainActor in onChange() }
                },
            ]
        }
        observations = geometryViews.map { view in
            view.observe(\.isHidden, options: [.new]) { _, _ in
                frameworkInvalidation.lock.withLock { $0 = true }
                Task { @MainActor in onChange() }
            }
        }
        // Nested splits can be inserted under known layout containers after cache
        // warm-up. Keep this bounded to root/direct/split-related containers, not
        // arbitrary descendants such as WebKit or terminal internals.
        observations.append(contentsOf: subviewObservedViews.map { view in
            view.observe(\.subviews, options: [.new]) { _, _ in
                frameworkInvalidation.lock.withLock { $0 = true }
                Task { @MainActor in onChange() }
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
        frameworkInvalidation.lock.withLock { $0 = false }
    }

    /// AppKit may change a container's subviews without delivering KVO. Check
    /// only the already-observed layout containers before reusing a pointer cache.
    func structureIsCurrent() -> Bool {
        guard !frameworkInvalidation.lock.withLock({ $0 }) else { return false }
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
