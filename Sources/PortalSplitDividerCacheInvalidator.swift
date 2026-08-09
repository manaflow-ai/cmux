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
        let previousWindow = subview.window
        cmux_portalAddSubview(subview)
        PortalViewHierarchyMutationTracker.recordInsertion(
            parentView: self,
            insertedView: subview,
            previousWindow: previousWindow
        )
    }

    @objc(cmux_portalAddSubview:positioned:relativeTo:)
    func cmux_portalAddSubview(
        _ subview: NSView,
        positioned place: NSWindow.OrderingMode,
        relativeTo otherView: NSView?
    ) {
        let previousWindow = subview.window
        cmux_portalAddSubview(subview, positioned: place, relativeTo: otherView)
        PortalViewHierarchyMutationTracker.recordInsertion(
            parentView: self,
            insertedView: subview,
            previousWindow: previousWindow
        )
    }

    @objc(cmux_portalSetSubviews:)
    func cmux_portalSetSubviews(_ newSubviews: [NSView]) {
        let replacementState = PortalViewHierarchyMutationTracker.subviewsBeforeReplacement(
            parentView: self,
            newSubviews: newSubviews
        )
        cmux_portalSetSubviews(newSubviews)
        guard let replacementState else { return }
        PortalViewHierarchyMutationTracker.recordSubviewsReplacement(
            parentView: self,
            newSubviews: newSubviews,
            replacementState: replacementState
        )
    }

    @objc func cmux_portalRemoveFromSuperview() {
        let oldSuperview = superview
        let previousWindow = window
        cmux_portalRemoveFromSuperview()
        if let oldSuperview {
            PortalViewHierarchyMutationTracker.recordRemoval(
                parentView: oldSuperview,
                removedView: self,
                previousWindow: previousWindow
            )
        }
    }

    @objc func cmux_portalRemoveFromSuperviewWithoutNeedingDisplay() {
        let oldSuperview = superview
        let previousWindow = window
        cmux_portalRemoveFromSuperviewWithoutNeedingDisplay()
        if let oldSuperview {
            PortalViewHierarchyMutationTracker.recordRemoval(
                parentView: oldSuperview,
                removedView: self,
                previousWindow: previousWindow
            )
        }
    }

    @objc func cmux_portalReplaceSubview(_ oldView: NSView, with newView: NSView) {
        let parentWindow = window
        let newViewPreviousWindow = newView.window
        cmux_portalReplaceSubview(oldView, with: newView)
        PortalViewHierarchyMutationTracker.recordReplacement(
            parentView: self,
            oldView: oldView,
            newView: newView,
            newViewPreviousWindow: newViewPreviousWindow,
            parentWindow: parentWindow
        )
    }

    @objc func cmux_portalSortSubviews(
        _ compare: PortalSubviewComparator,
        context: UnsafeMutableRawPointer?
    ) {
        let parentWindow = window
        let sortState = PortalViewHierarchyMutationTracker.subviewOrderBeforeSort(
            parentView: self,
            parentWindow: parentWindow
        )
        cmux_portalSortSubviews(compare, context: context)
        guard let sortState else { return }
        PortalViewHierarchyMutationTracker.recordSortIfNeeded(
            parentView: self,
            sortState: sortState
        )
    }
}

private extension NSSplitView {
    @objc(cmux_portalAddArrangedSubview:)
    func cmux_portalAddArrangedSubview(_ view: NSView) {
        let mutationState = PortalViewHierarchyMutationTracker.arrangedSubviewsBeforeMutation(
            splitView: self
        )
        cmux_portalAddArrangedSubview(view)
        guard let mutationState else { return }
        PortalViewHierarchyMutationTracker.recordArrangedSubviewsMutation(
            splitView: self,
            mutationState: mutationState
        )
    }

    @objc(cmux_portalInsertArrangedSubview:atIndex:)
    func cmux_portalInsertArrangedSubview(_ view: NSView, at index: Int) {
        let mutationState = PortalViewHierarchyMutationTracker.arrangedSubviewsBeforeMutation(
            splitView: self
        )
        cmux_portalInsertArrangedSubview(view, at: index)
        guard let mutationState else { return }
        PortalViewHierarchyMutationTracker.recordArrangedSubviewsMutation(
            splitView: self,
            mutationState: mutationState
        )
    }

    @objc(cmux_portalRemoveArrangedSubview:)
    func cmux_portalRemoveArrangedSubview(_ view: NSView) {
        let mutationState = PortalViewHierarchyMutationTracker.arrangedSubviewsBeforeMutation(
            splitView: self
        )
        cmux_portalRemoveArrangedSubview(view)
        guard let mutationState else { return }
        PortalViewHierarchyMutationTracker.recordArrangedSubviewsMutation(
            splitView: self,
            mutationState: mutationState
        )
    }

    @objc(cmux_portalSetArrangesAllSubviews:)
    func cmux_portalSetArrangesAllSubviews(_ arrangesAllSubviews: Bool) {
        let mutationState = PortalViewHierarchyMutationTracker.arrangedSubviewsBeforeMutation(
            splitView: self
        )
        cmux_portalSetArrangesAllSubviews(arrangesAllSubviews)
        guard let mutationState else { return }
        PortalViewHierarchyMutationTracker.recordArrangedSubviewsMutation(
            splitView: self,
            mutationState: mutationState
        )
    }
}

@MainActor
final class PortalSplitDividerCacheInvalidator {
    /// AppKit does not document `subviews` as KVO-compliant, and an `NSSplitView`
    /// can change its arranged panes without changing `subviews`. Hook both
    /// authoritative mutation surfaces once so the window tracker can advance
    /// its generation without a pointer-time tree walk.
    private static let hierarchyMutationHooksInstalled: Bool = {
        let selectorPairs: [(ownerClass: AnyClass, original: Selector, replacement: Selector)] = [
            (NSView.self, #selector(NSView.addSubview(_:)), #selector(NSView.cmux_portalAddSubview(_:))),
            (
                NSView.self,
                #selector(NSView.addSubview(_:positioned:relativeTo:)),
                #selector(NSView.cmux_portalAddSubview(_:positioned:relativeTo:))
            ),
            (NSView.self, #selector(setter: NSView.subviews), #selector(NSView.cmux_portalSetSubviews(_:))),
            (NSView.self, #selector(NSView.removeFromSuperview), #selector(NSView.cmux_portalRemoveFromSuperview)),
            (
                NSView.self,
                #selector(NSView.removeFromSuperviewWithoutNeedingDisplay),
                #selector(NSView.cmux_portalRemoveFromSuperviewWithoutNeedingDisplay)
            ),
            (
                NSView.self,
                #selector(NSView.replaceSubview(_:with:)),
                #selector(NSView.cmux_portalReplaceSubview(_:with:))
            ),
            (
                NSView.self,
                #selector(NSView.sortSubviews(_:context:)),
                #selector(NSView.cmux_portalSortSubviews(_:context:))
            ),
            (
                NSSplitView.self,
                #selector(NSSplitView.addArrangedSubview(_:)),
                #selector(NSSplitView.cmux_portalAddArrangedSubview(_:))
            ),
            (
                NSSplitView.self,
                #selector(NSSplitView.insertArrangedSubview(_:at:)),
                #selector(NSSplitView.cmux_portalInsertArrangedSubview(_:at:))
            ),
            (
                NSSplitView.self,
                #selector(NSSplitView.removeArrangedSubview(_:)),
                #selector(NSSplitView.cmux_portalRemoveArrangedSubview(_:))
            ),
            (
                NSSplitView.self,
                #selector(setter: NSSplitView.arrangesAllSubviews),
                #selector(NSSplitView.cmux_portalSetArrangesAllSubviews(_:))
            ),
        ]

        var methodPairs: [(original: Method, replacement: Method)] = []
        for selectors in selectorPairs {
            guard let original = class_getInstanceMethod(selectors.ownerClass, selectors.original),
                  let replacement = class_getInstanceMethod(selectors.ownerClass, selectors.replacement) else {
                assertionFailure("Unable to install portal view-hierarchy mutation hook for \(selectors.original)")
                return false
            }
            methodPairs.append((original, replacement))
        }
        for methods in methodPairs {
            method_exchangeImplementations(methods.original, methods.replacement)
        }
        return true
    }()

    // Observer tokens are assigned/cleared from main-thread AppKit paths. Swift
    // deinit is nonisolated, so the teardown helper needs nonisolated access
    // after all main-thread use has ceased.
    private nonisolated(unsafe) var observations: [NSKeyValueObservation] = []
    private nonisolated(unsafe) var notificationObservers: [NSObjectProtocol] = []
    private var hierarchyRegistration: PortalViewHierarchyMutationRegistration?

    init() {
        _ = Self.hierarchyMutationHooksInstalled
    }

    deinit {
        invalidateObservations()
    }

    func observe(
        rootView: NSView,
        geometryViews: [NSView],
        hierarchyNodes: [(view: NSView, containsSplitView: Bool)],
        onChange: @escaping @MainActor () -> Void
    ) {
        invalidate()
        let geometryViews = Self.uniqueViews(geometryViews)
        hierarchyRegistration = PortalViewHierarchyMutationTracker.register(
            rootView: rootView,
            hierarchyNodes: hierarchyNodes
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
        hierarchyRegistration = nil
        invalidateObservations()
    }

    func isHierarchyCurrent(for rootView: NSView) -> Bool {
        guard Self.hierarchyMutationHooksInstalled else { return false }
        return hierarchyRegistration?.isCurrent(for: rootView) == true
    }

    private nonisolated func invalidateObservations() {
        observations.removeAll()
        notificationObservers.forEach(NotificationCenter.default.removeObserver)
        notificationObservers.removeAll()
    }
}
