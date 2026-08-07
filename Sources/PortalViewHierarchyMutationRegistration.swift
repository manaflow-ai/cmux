import AppKit

/// Weak lifetime token connecting one live divider cache to its window tracker.
@MainActor
final class PortalViewHierarchyMutationRegistration: NSObject {
    private weak var tracker: PortalViewHierarchyMutationTracker?
    private weak var rootView: NSView?
    private let generation: UInt64

    init(
        tracker: PortalViewHierarchyMutationTracker,
        rootView: NSView,
        generation: UInt64
    ) {
        self.tracker = tracker
        self.rootView = rootView
        self.generation = generation
    }

    func isCurrent(for rootView: NSView) -> Bool {
        tracker?.isCurrent(
            registrationGeneration: generation,
            registeredRootView: self.rootView,
            requestedRootView: rootView
        ) == true
    }
}
