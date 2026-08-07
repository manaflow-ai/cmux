import AppKit

/// Routes relevant hierarchy mutations to the active divider-cache owners for one root view.
@MainActor
final class PortalViewHierarchyMutationHub: NSObject {
    private weak var rootView: NSView?
    private let invalidators = NSHashTable<PortalSplitDividerCacheInvalidator>.weakObjects()

    init(rootView: NSView) {
        self.rootView = rootView
    }

    func add(_ invalidator: PortalSplitDividerCacheInvalidator) {
        invalidators.add(invalidator)
    }

    func notify() {
        guard let rootView else { return }
        for invalidator in invalidators.allObjects {
            invalidator.viewHierarchyDidMutate(in: rootView)
        }
    }
}
