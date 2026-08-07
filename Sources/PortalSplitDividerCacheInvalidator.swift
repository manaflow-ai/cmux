import AppKit
import ObjectiveC

private extension Notification.Name {
    static let portalViewHierarchyDidMutate = Notification.Name("cmux.portalViewHierarchyDidMutate")
}

private extension NSView {
    @objc func cmux_portalDidAddSubview(_ subview: NSView) {
        cmux_portalDidAddSubview(subview)
        NotificationCenter.default.post(name: .portalViewHierarchyDidMutate, object: subview)
    }

    @objc func cmux_portalWillRemoveSubview(_ subview: NSView) {
        // Notify while the child still identifies the hierarchy it is leaving.
        NotificationCenter.default.post(name: .portalViewHierarchyDidMutate, object: subview)
        cmux_portalWillRemoveSubview(subview)
    }
}

@MainActor
final class PortalSplitDividerCacheInvalidator {
    /// AppKit does not document `subviews` as KVO-compliant, but it does provide
    /// these callbacks for every hierarchy insertion and removal. Hook the base
    /// implementations once so active portal caches can invalidate at mutation
    /// time instead of walking the entire view tree on every pointer event.
    private static let installViewHierarchyMutationHooks: Void = {
        guard let originalDidAddSubview = class_getInstanceMethod(
            NSView.self,
            #selector(NSView.didAddSubview(_:))
        ), let hookedDidAddSubview = class_getInstanceMethod(
            NSView.self,
            #selector(NSView.cmux_portalDidAddSubview(_:))
        ), let originalWillRemoveSubview = class_getInstanceMethod(
            NSView.self,
            #selector(NSView.willRemoveSubview(_:))
        ), let hookedWillRemoveSubview = class_getInstanceMethod(
            NSView.self,
            #selector(NSView.cmux_portalWillRemoveSubview(_:))
        ) else {
            assertionFailure("Unable to install portal view-hierarchy mutation hooks")
            return
        }

        method_exchangeImplementations(originalDidAddSubview, hookedDidAddSubview)
        method_exchangeImplementations(originalWillRemoveSubview, hookedWillRemoveSubview)
    }()

    // Observer tokens are assigned/cleared from main-thread AppKit paths. Swift
    // deinit is nonisolated, so the teardown helper needs nonisolated access
    // after all main-thread use has ceased.
    private nonisolated(unsafe) var observations: [NSKeyValueObservation] = []
    private nonisolated(unsafe) var notificationObservers: [NSObjectProtocol] = []

    init() {
        _ = Self.installViewHierarchyMutationHooks
    }

    deinit {
        invalidateObservations()
    }

    func observe(
        rootView: NSView,
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
        notificationObservers.append(NotificationCenter.default.addObserver(
            forName: .portalViewHierarchyDidMutate,
            object: nil,
            queue: nil
        ) { [weak rootView] notification in
            MainActor.assumeIsolated {
                guard let rootView,
                      let changedSubview = notification.object as? NSView,
                      let parent = changedSubview.superview,
                      parent === rootView || parent.isDescendant(of: rootView),
                      parent is NSSplitView || PortalSplitDividerRegion.containsSplitView(in: changedSubview) else {
                    return
                }
                onChange()
            }
        })
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
    }

    private nonisolated func invalidateObservations() {
        observations.removeAll()
        notificationObservers.forEach(NotificationCenter.default.removeObserver)
        notificationObservers.removeAll()
    }
}
