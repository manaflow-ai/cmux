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
    // Each entry exists only across one synchronous `sortSubviews` call and is
    // removed by `finishSort`, including nested sorts of the same parent.
    private var activeSortDepths: [ObjectIdentifier: Int] = [:]

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
        tracker.index(hierarchyNodes, rootView: rootView)
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
        insertedView: NSView
    ) {
        guard let window = parentView.window,
              let tracker = tracker(for: window, createIfNeeded: false),
              tracker.hasActiveCaches else {
            return
        }
        tracker.recordInsertion(
            parentView: parentView,
            insertedView: insertedView
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
        oldView: NSView,
        newView: NSView,
        parentWindow: NSWindow?
    ) {
        guard let window = parentWindow,
              let tracker = tracker(for: window, createIfNeeded: false),
              tracker.hasActiveCaches else {
            return
        }
        tracker.recordReplacement(
            parentView: parentView,
            oldView: oldView,
            newView: newView
        )
    }

    static func recordSubviewsReplacement(
        parentView: NSView,
        parentWindow: NSWindow?,
        newSubviews: [NSView]
    ) {
        guard let window = parentWindow,
              let tracker = tracker(for: window, createIfNeeded: false),
              tracker.hasActiveCaches else {
            return
        }
        tracker.recordSubviewsReplacement(parentView: parentView, newSubviews: newSubviews)
    }

    static func subviewOrderBeforeSort(
        parentView: NSView,
        parentWindow: NSWindow?
    ) -> [NSView]? {
        guard let window = parentWindow,
              let tracker = tracker(for: window, createIfNeeded: false),
              tracker.hasActiveCaches,
              let parentState = tracker.currentNodeState(for: parentView),
              parentState.containsSplitView else {
            return nil
        }
        tracker.beginSort(parentView: parentView)
        return parentView.subviews
    }

    static func recordSortIfNeeded(
        parentView: NSView,
        parentWindow: NSWindow?,
        previousSubviews: [NSView]
    ) {
        guard let window = parentWindow,
              let tracker = tracker(for: window, createIfNeeded: false),
              tracker.finishSort(parentView: parentView) else {
            return
        }
        guard tracker.hasActiveCaches,
              let parentState = tracker.currentNodeState(for: parentView),
              parentState.containsSplitView,
              !haveSameIdentityOrder(previousSubviews, parentView.subviews) else { return }
        tracker.markDirty()
    }

    private static func haveSameIdentityOrder(_ lhs: [NSView], _ rhs: [NSView]) -> Bool {
        guard lhs.count == rhs.count else { return false }
        return zip(lhs, rhs).allSatisfy { $0 === $1 }
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
            && currentNodeState(for: requestedRootView)?.registeredRootGeneration == generation
    }

    private func index(
        _ nodes: [(view: NSView, containsSplitView: Bool)],
        rootView: NSView
    ) {
        for node in nodes {
            guard let state = nodeState(for: node.view, createIfNeeded: true) else { continue }
            state.tracker = self
            state.generation = generation
            state.containsSplitView = node.containsSplitView
        }
        currentNodeState(for: rootView)?.registeredRootGeneration = generation
    }

    private func recordInsertion(
        parentView: NSView,
        insertedView: NSView
    ) {
        guard !isSorting(parentView: parentView) else { return }
        guard let parentState = currentNodeState(for: parentView) else {
            if isCurrentRegisteredRoot(insertedView) {
                markDirty()
            }
            return
        }
        if parentState.containsSplitView || insertedView is NSSplitView {
            markDirty()
            return
        }

        if let insertedState = currentNodeState(for: insertedView) {
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
        guard !isSorting(parentView: parentView) else { return }
        guard let parentState = currentNodeState(for: parentView) else {
            if isCurrentRegisteredRoot(removedView) {
                markDirty()
            }
            return
        }
        if parentState.containsSplitView || currentNodeState(for: removedView)?.containsSplitView == true {
            markDirty()
        }
    }

    private func recordReplacement(parentView: NSView, oldView: NSView, newView: NSView) {
        guard !isSorting(parentView: parentView) else { return }
        guard currentNodeState(for: parentView) != nil else {
            if isCurrentRegisteredRoot(oldView) || isCurrentRegisteredRoot(newView) {
                markDirty()
            }
            return
        }
        recordInsertion(parentView: parentView, insertedView: newView)
    }

    private func recordSubviewsReplacement(parentView: NSView, newSubviews: [NSView]) {
        guard !isSorting(parentView: parentView) else { return }
        if currentNodeState(for: parentView) != nil
            || newSubviews.contains(where: isCurrentRegisteredRoot) {
            markDirty()
        }
    }

    private func isCurrentRegisteredRoot(_ view: NSView) -> Bool {
        currentNodeState(for: view)?.registeredRootGeneration == generation
    }

    private func beginSort(parentView: NSView) {
        activeSortDepths[ObjectIdentifier(parentView), default: 0] += 1
    }

    private func finishSort(parentView: NSView) -> Bool {
        let id = ObjectIdentifier(parentView)
        guard let depth = activeSortDepths[id], depth > 0 else { return false }
        if depth == 1 {
            activeSortDepths.removeValue(forKey: id)
        } else {
            activeSortDepths[id] = depth - 1
        }
        return true
    }

    private func isSorting(parentView: NSView) -> Bool {
        activeSortDepths[ObjectIdentifier(parentView)] != nil
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
