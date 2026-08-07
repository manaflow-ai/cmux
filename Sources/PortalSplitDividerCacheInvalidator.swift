import AppKit
import ObjectiveC

private extension NSView {
    @objc func cmux_portalDidAddSubview(_ subview: NSView) {
        cmux_portalDidAddSubview(subview)
        PortalSplitDividerCacheInvalidator.viewHierarchyDidMutate(
            parentView: self,
            changedSubview: subview
        )
    }

    @objc func cmux_portalWillRemoveSubview(_ subview: NSView) {
        // Notify while the child still identifies the hierarchy it is leaving.
        PortalSplitDividerCacheInvalidator.viewHierarchyDidMutate(
            parentView: self,
            changedSubview: subview
        )
        cmux_portalWillRemoveSubview(subview)
    }
}

@MainActor
final class PortalSplitDividerCacheInvalidator {
    private static let hierarchyMutationHubAssociationKey = NSObject()

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
    private weak var hierarchyMutationRootView: NSView?
    private var hierarchyMutationOnChange: (@MainActor () -> Void)?

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
        hierarchyMutationRootView = rootView
        hierarchyMutationOnChange = onChange
        Self.hierarchyMutationHub(for: rootView, createIfNeeded: true)?.add(self)

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
        hierarchyMutationRootView = nil
        hierarchyMutationOnChange = nil
        invalidateObservations()
    }

    /// Ignores stale weak registrations left on roots this invalidator no longer observes.
    func viewHierarchyDidMutate(in rootView: NSView) {
        guard hierarchyMutationRootView === rootView else { return }
        hierarchyMutationOnChange?()
    }

    /// Routes a hierarchy mutation only to cache owners whose roots contain the
    /// changed parent. Relevance is classified once even when several portals
    /// share a root, avoiding process-wide observer fanout and repeated scans.
    fileprivate static func viewHierarchyDidMutate(parentView: NSView, changedSubview: NSView) {
        var hubs: [PortalViewHierarchyMutationHub] = []
        var ancestor: NSView? = parentView
        while let view = ancestor {
            if let hub = hierarchyMutationHub(for: view, createIfNeeded: false) {
                hubs.append(hub)
            }
            ancestor = view.superview
        }

        guard !hubs.isEmpty,
              parentView is NSSplitView || PortalSplitDividerRegion.containsSplitView(in: changedSubview) else {
            return
        }
        for hub in hubs {
            hub.notify()
        }
    }

    private static func hierarchyMutationHub(
        for rootView: NSView,
        createIfNeeded: Bool
    ) -> PortalViewHierarchyMutationHub? {
        let key = Unmanaged.passUnretained(hierarchyMutationHubAssociationKey).toOpaque()
        if let hub = objc_getAssociatedObject(rootView, key) as? PortalViewHierarchyMutationHub {
            return hub
        }
        guard createIfNeeded else { return nil }

        let hub = PortalViewHierarchyMutationHub(rootView: rootView)
        objc_setAssociatedObject(rootView, key, hub, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return hub
    }

    private nonisolated func invalidateObservations() {
        observations.removeAll()
        notificationObservers.forEach(NotificationCenter.default.removeObserver)
        notificationObservers.removeAll()
    }
}
