import AppKit
import ObjectiveC

/// Owns the divider-relevant structural generation for one AppKit window.
@MainActor
final class PortalViewHierarchyMutationTracker: NSObject {
    typealias SubviewOrderBeforeSort = (
        tracker: PortalViewHierarchyMutationTracker,
        subviews: [NSView]
    )
    typealias SubviewsBeforeReplacement = (
        tracker: PortalViewHierarchyMutationTracker,
        subviews: [NSView],
        newSubviewWasInTrackedWindow: [Bool]
    )
    typealias ArrangedSubviewsBeforeMutation = (
        tracker: PortalViewHierarchyMutationTracker,
        arrangedSubviews: [NSView]
    )

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

    private func beginRegistrationCycleIfNeeded() {
        guard !hasActiveCaches else { return }
        // Mutation hooks intentionally skip windows without a live cache.
        // Revoke every proof from the prior active interval before indexing
        // the first new cache, so dormant structural changes cannot revive it.
        generation &+= 1
    }

    static func register(
        rootView: NSView,
        hierarchyNodes: [(view: NSView, containsSplitView: Bool)]
    ) -> PortalViewHierarchyMutationRegistration? {
        guard let window = rootView.window,
              let tracker = tracker(for: window, createIfNeeded: true) else {
            return nil
        }
        tracker.beginRegistrationCycleIfNeeded()
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
        insertedView: NSView,
        previousWindow: NSWindow?
    ) {
        let parentWindow = parentView.window
        guard let tracker = mutationTracker(
            for: parentView,
            parentWindow: parentWindow
        ),
              tracker.hasActiveCaches else {
            return
        }
        tracker.recordInsertion(
            parentView: parentView,
            insertedView: insertedView,
            cameFromSameWindow: parentWindow != nil && previousWindow === parentWindow
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
        newViewPreviousWindow: NSWindow?,
        parentWindow: NSWindow?
    ) {
        guard let tracker = mutationTracker(
            for: parentView,
            parentWindow: parentWindow
        ),
              tracker.hasActiveCaches else {
            return
        }
        tracker.recordReplacement(
            parentView: parentView,
            oldView: oldView,
            newView: newView,
            newViewCameFromSameWindow: parentWindow != nil && newViewPreviousWindow === parentWindow
        )
    }

    static func subviewsBeforeReplacement(
        parentView: NSView,
        newSubviews: [NSView]
    ) -> SubviewsBeforeReplacement? {
        let parentWindow = parentView.window
        guard let tracker = mutationTracker(
            for: parentView,
            parentWindow: parentWindow
        ),
              tracker.hasActiveCaches else {
            return nil
        }
        return (
            tracker: tracker,
            subviews: parentView.subviews,
            newSubviewWasInTrackedWindow: newSubviews.map {
                parentWindow != nil && $0.window === parentWindow
            }
        )
    }

    static func recordSubviewsReplacement(
        parentView: NSView,
        newSubviews: [NSView],
        replacementState: SubviewsBeforeReplacement
    ) {
        replacementState.tracker.recordSubviewsReplacement(
            parentView: parentView,
            oldSubviews: replacementState.subviews,
            newSubviews: newSubviews,
            newSubviewWasInTrackedWindow: replacementState.newSubviewWasInTrackedWindow
        )
    }

    static func arrangedSubviewsBeforeMutation(
        splitView: NSSplitView
    ) -> ArrangedSubviewsBeforeMutation? {
        // A split-bearing indexed subtree cannot become windowless while its
        // registration stays current: `recordRemoval` advances the generation
        // at that boundary. Only in-window arranged mutations need a snapshot.
        guard let window = splitView.window,
              let tracker = tracker(for: window, createIfNeeded: false),
              tracker.hasActiveCaches,
              tracker.currentNodeState(for: splitView)?.containsSplitView == true else {
            return nil
        }
        return (
            tracker: tracker,
            arrangedSubviews: splitView.arrangedSubviews
        )
    }

    static func recordArrangedSubviewsMutation(
        splitView: NSSplitView,
        mutationState: ArrangedSubviewsBeforeMutation
    ) {
        let tracker = mutationState.tracker
        guard tracker.hasActiveCaches,
              tracker.currentNodeState(for: splitView)?.containsSplitView == true,
              !haveSameIdentityOrder(mutationState.arrangedSubviews, splitView.arrangedSubviews) else {
            return
        }
        tracker.markDirty()
    }

    static func subviewOrderBeforeSort(
        parentView: NSView,
        parentWindow: NSWindow?
    ) -> SubviewOrderBeforeSort? {
        // A parent whose index says it contains a split view dirties the
        // generation when detached, before a nil-window sort can occur.
        guard let window = parentWindow,
              let tracker = tracker(for: window, createIfNeeded: false),
              tracker.hasActiveCaches,
              let parentState = tracker.currentNodeState(for: parentView),
              parentState.containsSplitView else {
            return nil
        }
        tracker.beginSort(parentView: parentView)
        return (tracker: tracker, subviews: parentView.subviews)
    }

    static func recordSortIfNeeded(
        parentView: NSView,
        sortState: SubviewOrderBeforeSort
    ) {
        let tracker = sortState.tracker
        guard tracker.finishSort(parentView: parentView) else {
            return
        }
        guard tracker.hasActiveCaches,
              let parentState = tracker.currentNodeState(for: parentView),
              parentState.containsSplitView,
              !haveSameIdentityOrder(sortState.subviews, parentView.subviews) else { return }
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

    /// An indexed subtree can keep its split-free proof while detached. Route
    /// mutations through that proof's tracker even before the subtree rejoins
    /// a window, so a fresh wrapper cannot conceal detached structural changes.
    private static func mutationTracker(
        for parentView: NSView,
        parentWindow: NSWindow?
    ) -> PortalViewHierarchyMutationTracker? {
        if let parentWindow {
            return tracker(for: parentWindow, createIfNeeded: false)
        }
        return associatedNodeState(for: parentView)?.tracker
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
        insertedView: NSView,
        cameFromSameWindow: Bool
    ) {
        guard !isSorting(parentView: parentView) else { return }
        guard let parentState = currentNodeState(for: parentView) else {
            // Crossing from an indexed cache root into an unindexed window
            // branch breaks provenance for the entire moved subtree. Advancing
            // the generation revokes every descendant proof in constant time.
            if currentNodeState(for: insertedView) != nil {
                markDirty()
            }
            return
        }
        if parentState.containsSplitView || insertedView is NSSplitView {
            markDirty()
            return
        }

        // A node-state proof is reusable only while the subtree stayed in this
        // window, where every hierarchy mutation passed through this tracker.
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

    private func recordReplacement(
        parentView: NSView,
        oldView: NSView,
        newView: NSView,
        newViewCameFromSameWindow: Bool
    ) {
        guard !isSorting(parentView: parentView) else { return }
        guard currentNodeState(for: parentView) != nil else {
            if isCurrentRegisteredRoot(oldView)
                || currentNodeState(for: newView) != nil {
                markDirty()
            }
            return
        }
        recordInsertion(
            parentView: parentView,
            insertedView: newView,
            cameFromSameWindow: newViewCameFromSameWindow
        )
    }

    private func recordSubviewsReplacement(
        parentView: NSView,
        oldSubviews: [NSView],
        newSubviews: [NSView],
        newSubviewWasInTrackedWindow: [Bool]
    ) {
        guard !isSorting(parentView: parentView),
              hasActiveCaches,
              !Self.haveSameIdentityOrder(oldSubviews, newSubviews) else { return }
        guard let parentState = currentNodeState(for: parentView) else {
            let touchesRegisteredRoot = oldSubviews.contains(where: isCurrentRegisteredRoot)
            let movesIndexedProofOutsideRoot = newSubviews.contains {
                currentNodeState(for: $0) != nil
            }
            if touchesRegisteredRoot || movesIndexedProofOutsideRoot {
                markDirty()
            }
            return
        }
        guard !parentState.containsSplitView else {
            markDirty()
            return
        }

        for (newSubview, wasInTrackedWindow) in zip(newSubviews, newSubviewWasInTrackedWindow) {
            if newSubview is NSSplitView {
                markDirty()
                return
            }
            if wasInTrackedWindow,
               let newSubviewState = currentNodeState(for: newSubview) {
                if newSubviewState.containsSplitView {
                    markDirty()
                    return
                }
                continue
            }
            guard newSubview.subviews.isEmpty else {
                markDirty()
                return
            }
            guard let newSubviewState = nodeState(for: newSubview, createIfNeeded: true) else {
                markDirty()
                return
            }
            newSubviewState.tracker = self
            newSubviewState.generation = generation
            newSubviewState.containsSplitView = false
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
        if let state = Self.associatedNodeState(for: view) {
            return state
        }
        guard createIfNeeded else { return nil }

        let state = PortalViewHierarchyNodeState()
        let key = Unmanaged.passUnretained(Self.nodeStateAssociationKey).toOpaque()
        objc_setAssociatedObject(view, key, state, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return state
    }

    private static func associatedNodeState(for view: NSView) -> PortalViewHierarchyNodeState? {
        let key = Unmanaged.passUnretained(nodeStateAssociationKey).toOpaque()
        return objc_getAssociatedObject(view, key) as? PortalViewHierarchyNodeState
    }

    private func markDirty() {
        // Cache owners compare this lazily on their next pointer lookup. Keeping
        // the mutation boundary callback-free prevents work from scaling with
        // the number of terminal and browser portals in the window.
        generation &+= 1
    }
}
