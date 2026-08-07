import AppKit
import ObjectiveC

/// Owns the divider-relevant structural generation for one AppKit window.
@MainActor
final class PortalViewHierarchyMutationTracker: NSObject {
    private static let windowAssociationKey = NSObject()
    private static let nodeStateAssociationKey = NSObject()

    private weak var window: NSWindow?
    private var generation: UInt64 = 0
    private let registrations = NSHashTable<PortalViewHierarchyMutationRegistration>.weakObjects()

    private init(window: NSWindow) {
        self.window = window
    }

    private var hasActiveCaches: Bool {
        registrations.anyObject != nil
    }

    static func register(
        rootView: NSView,
        hierarchyNodes: [(view: NSView, containsSplitView: Bool)]
    ) -> PortalViewHierarchyMutationRegistration? {
        guard let window = rootView.window,
              let tracker = tracker(for: window, createIfNeeded: true) else {
            return nil
        }
        tracker.index(hierarchyNodes)
        let registration = PortalViewHierarchyMutationRegistration(
            tracker: tracker,
            rootView: rootView,
            generation: tracker.generation
        )
        tracker.registrations.add(registration)
        return registration
    }

    /// Records an insertion after AppKit has attached the child. Unknown
    /// prebuilt subtrees fail closed, while a leaf under an indexed no-split
    /// branch stays on the fast path without a full cache rebuild.
    static func recordInsertion(
        parentView: NSView,
        insertedView: NSView,
        previousWindow: NSWindow?
    ) {
        guard let window = parentView.window,
              let tracker = tracker(for: window, createIfNeeded: false),
              tracker.hasActiveCaches else {
            return
        }
        tracker.recordInsertion(
            parentView: parentView,
            insertedView: insertedView,
            cameFromSameWindow: previousWindow === window
        )
    }

    static func recordRemoval(
        parentView: NSView,
        removedView: NSView,
        previousWindow: NSWindow?
    ) {
        guard let window = previousWindow,
              let tracker = tracker(for: window, createIfNeeded: false),
              tracker.hasActiveCaches else {
            return
        }
        tracker.recordRemoval(parentView: parentView, removedView: removedView)
    }

    static func recordReplacement(
        parentView: NSView,
        newView: NSView,
        newViewPreviousWindow: NSWindow?,
        parentWindow: NSWindow?
    ) {
        guard let window = parentWindow,
              let tracker = tracker(for: window, createIfNeeded: false),
              tracker.hasActiveCaches else {
            return
        }
        tracker.recordInsertion(
            parentView: parentView,
            insertedView: newView,
            cameFromSameWindow: newViewPreviousWindow === window
        )
    }

    static func recordSubviewsReplacement(parentView: NSView, parentWindow: NSWindow?) {
        guard let window = parentWindow,
              let tracker = tracker(for: window, createIfNeeded: false),
              tracker.hasActiveCaches,
              tracker.currentNodeState(for: parentView) != nil else {
            return
        }
        tracker.markDirty()
    }

    static func recordSort(parentView: NSView, parentWindow: NSWindow?) {
        guard let window = parentWindow,
              let tracker = tracker(for: window, createIfNeeded: false),
              tracker.hasActiveCaches,
              let parentState = tracker.currentNodeState(for: parentView),
              parentState.containsSplitView else {
            return
        }
        tracker.markDirty()
    }

    private static func tracker(
        for window: NSWindow,
        createIfNeeded: Bool
    ) -> PortalViewHierarchyMutationTracker? {
        let key = Unmanaged.passUnretained(windowAssociationKey).toOpaque()
        if let tracker = objc_getAssociatedObject(window, key) as? PortalViewHierarchyMutationTracker {
            return tracker
        }
        guard createIfNeeded else { return nil }

        let tracker = PortalViewHierarchyMutationTracker(window: window)
        objc_setAssociatedObject(window, key, tracker, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return tracker
    }

    func isCurrent(
        registrationGeneration: UInt64,
        registeredRootView: NSView?,
        requestedRootView: NSView
    ) -> Bool {
        registeredRootView === requestedRootView
            && requestedRootView.window === window
            && registrationGeneration == generation
    }

    private func index(_ nodes: [(view: NSView, containsSplitView: Bool)]) {
        for node in nodes {
            guard let state = nodeState(for: node.view, createIfNeeded: true) else { continue }
            state.tracker = self
            state.generation = generation
            state.containsSplitView = node.containsSplitView
        }
    }

    private func recordInsertion(
        parentView: NSView,
        insertedView: NSView,
        cameFromSameWindow: Bool
    ) {
        guard let parentState = currentNodeState(for: parentView) else { return }
        if parentState.containsSplitView || insertedView is NSSplitView {
            markDirty()
            return
        }

        if cameFromSameWindow,
           let insertedState = currentNodeState(for: insertedView) {
            if insertedState.containsSplitView {
                markDirty()
            }
            return
        }

        // `subviews` bridges AppKit's retained array and `isEmpty` reads only
        // its count. Never recurse through an untrusted prebuilt subtree here.
        guard insertedView.subviews.isEmpty else {
            markDirty()
            return
        }
        guard let insertedState = nodeState(for: insertedView, createIfNeeded: true) else { return }
        insertedState.tracker = self
        insertedState.generation = generation
        insertedState.containsSplitView = false
    }

    private func recordRemoval(parentView: NSView, removedView: NSView) {
        guard let parentState = currentNodeState(for: parentView) else { return }
        if parentState.containsSplitView || currentNodeState(for: removedView)?.containsSplitView == true {
            markDirty()
        }
    }

    private func currentNodeState(for view: NSView) -> PortalViewHierarchyNodeState? {
        let state = nodeState(for: view, createIfNeeded: false)
        guard state?.tracker === self, state?.generation == generation else { return nil }
        return state
    }

    private func nodeState(for view: NSView, createIfNeeded: Bool) -> PortalViewHierarchyNodeState? {
        let key = Unmanaged.passUnretained(Self.nodeStateAssociationKey).toOpaque()
        if let state = objc_getAssociatedObject(view, key) as? PortalViewHierarchyNodeState {
            return state
        }
        guard createIfNeeded else { return nil }

        let state = PortalViewHierarchyNodeState()
        objc_setAssociatedObject(view, key, state, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return state
    }

    private func markDirty() {
        // Cache owners compare this lazily on their next pointer lookup. Keeping
        // the mutation boundary callback-free prevents work from scaling with
        // the number of terminal and browser portals in the window.
        generation &+= 1
    }
}
