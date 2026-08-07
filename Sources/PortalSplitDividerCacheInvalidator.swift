import AppKit
import ObjectiveC

private typealias PortalSubviewComparator = @convention(c) (
    NSView,
    NSView,
    UnsafeMutableRawPointer?
) -> ComparisonResult

private extension NSView {
    @objc(cmux_portalAddSubview:)
    func cmux_portalAddSubview(_ subview: NSView) {
        cmux_portalAddSubview(subview)
        PortalSplitDividerCacheInvalidator.viewHierarchyDidMutate(
            parentView: self,
            changedSubviews: [subview]
        )
    }

    @objc(cmux_portalAddSubview:positioned:relativeTo:)
    func cmux_portalAddSubview(
        _ subview: NSView,
        positioned place: NSWindow.OrderingMode,
        relativeTo otherView: NSView?
    ) {
        cmux_portalAddSubview(subview, positioned: place, relativeTo: otherView)
        PortalSplitDividerCacheInvalidator.viewHierarchyDidMutate(
            parentView: self,
            changedSubviews: [subview]
        )
    }

    @objc(cmux_portalSetSubviews:)
    func cmux_portalSetSubviews(_ newSubviews: [NSView]) {
        let oldSubviews = subviews
        cmux_portalSetSubviews(newSubviews)
        PortalSplitDividerCacheInvalidator.viewHierarchyDidMutate(
            parentView: self,
            changedSubviews: oldSubviews + newSubviews
        )
    }

    @objc func cmux_portalRemoveFromSuperview() {
        let oldSuperview = superview
        cmux_portalRemoveFromSuperview()
        if let oldSuperview {
            PortalSplitDividerCacheInvalidator.viewHierarchyDidMutate(
                parentView: oldSuperview,
                changedSubviews: [self]
            )
        }
    }

    @objc func cmux_portalRemoveFromSuperviewWithoutNeedingDisplay() {
        let oldSuperview = superview
        cmux_portalRemoveFromSuperviewWithoutNeedingDisplay()
        if let oldSuperview {
            PortalSplitDividerCacheInvalidator.viewHierarchyDidMutate(
                parentView: oldSuperview,
                changedSubviews: [self]
            )
        }
    }

    @objc func cmux_portalReplaceSubview(_ oldView: NSView, with newView: NSView) {
        cmux_portalReplaceSubview(oldView, with: newView)
        PortalSplitDividerCacheInvalidator.viewHierarchyDidMutate(
            parentView: self,
            changedSubviews: [oldView, newView]
        )
    }

    @objc func cmux_portalSortSubviews(
        _ compare: PortalSubviewComparator,
        context: UnsafeMutableRawPointer?
    ) {
        cmux_portalSortSubviews(compare, context: context)
        PortalSplitDividerCacheInvalidator.viewHierarchyDidMutate(
            parentView: self,
            changedSubviews: []
        )
    }
}

@MainActor
final class PortalSplitDividerCacheInvalidator {
    private static let hierarchyMutationHubAssociationKey = NSObject()

    /// AppKit does not document `subviews` as KVO-compliant. Hook every public
    /// hierarchy mutation entrypoint once so active portal caches invalidate at
    /// mutation time instead of walking the view tree on every pointer event.
    private static let installViewHierarchyMutationHooks: Void = {
        let selectorPairs: [(original: Selector, replacement: Selector)] = [
            (#selector(NSView.addSubview(_:)), #selector(NSView.cmux_portalAddSubview(_:))),
            (
                #selector(NSView.addSubview(_:positioned:relativeTo:)),
                #selector(NSView.cmux_portalAddSubview(_:positioned:relativeTo:))
            ),
            (#selector(setter: NSView.subviews), #selector(NSView.cmux_portalSetSubviews(_:))),
            (#selector(NSView.removeFromSuperview), #selector(NSView.cmux_portalRemoveFromSuperview)),
            (
                #selector(NSView.removeFromSuperviewWithoutNeedingDisplay),
                #selector(NSView.cmux_portalRemoveFromSuperviewWithoutNeedingDisplay)
            ),
            (
                #selector(NSView.replaceSubview(_:with:)),
                #selector(NSView.cmux_portalReplaceSubview(_:with:))
            ),
            (#selector(NSView.sortSubviews(_:context:)), #selector(NSView.cmux_portalSortSubviews(_:context:))),
        ]

        var methodPairs: [(original: Method, replacement: Method)] = []
        for selectors in selectorPairs {
            guard let original = class_getInstanceMethod(NSView.self, selectors.original),
                  let replacement = class_getInstanceMethod(NSView.self, selectors.replacement) else {
                assertionFailure("Unable to install portal view-hierarchy mutation hook for \(selectors.original)")
                return
            }
            methodPairs.append((original, replacement))
        }
        for methods in methodPairs {
            method_exchangeImplementations(methods.original, methods.replacement)
        }
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
        let hierarchyStructureViews = Self.uniqueViews([rootView] + subviewObservedViews)
        hierarchyMutationRootView = rootView
        hierarchyMutationOnChange = onChange
        Self.hierarchyMutationHub(for: rootView, createIfNeeded: true)?.add(
            self,
            structureViews: hierarchyStructureViews
        )

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
        if let hierarchyMutationRootView {
            Self.hierarchyMutationHub(for: hierarchyMutationRootView, createIfNeeded: false)?.remove(self)
        }
        hierarchyMutationRootView = nil
        hierarchyMutationOnChange = nil
        invalidateObservations()
    }

    /// Ignores stale weak registrations left on roots this invalidator no longer observes.
    func viewHierarchyDidMutate(in rootView: NSView) {
        guard hierarchyMutationRootView === rootView,
              let onChange = hierarchyMutationOnChange else { return }
        invalidate()
        onChange()
    }

    /// Routes a hierarchy mutation only to cache owners whose roots contain the
    /// changed parent. Relevance is classified once even when several portals
    /// share a root, avoiding process-wide observer fanout and repeated scans.
    fileprivate static func viewHierarchyDidMutate(parentView: NSView, changedSubviews: [NSView]) {
        var hubs: [PortalViewHierarchyMutationHub] = []
        var ancestor: NSView? = parentView
        while let view = ancestor {
            if let hub = hierarchyMutationHub(for: view, createIfNeeded: false),
               hub.hasActiveCaches {
                hubs.append(hub)
            }
            ancestor = view.superview
        }

        guard !hubs.isEmpty else { return }
        let parentIsSplitView = parentView is NSSplitView
        let structureObservations = hubs.map { $0.observesStructure(of: parentView) }
        let changedSubtreeContainsSplitView =
            !parentIsSplitView &&
            structureObservations.contains(false) &&
            changedSubviews.contains { PortalSplitDividerRegion.containsSplitView(in: $0) }
        for (hub, observesParent) in zip(hubs, structureObservations) {
            if parentIsSplitView || changedSubtreeContainsSplitView || observesParent {
                hub.notify()
            }
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
