import AppKit

/// Routes relevant hierarchy mutations to the active divider-cache owners for one root view.
@MainActor
final class PortalViewHierarchyMutationHub: NSObject {
    private weak var rootView: NSView?
    private let structureViewsByInvalidator = NSMapTable<
        PortalSplitDividerCacheInvalidator,
        NSHashTable<NSView>
    >(keyOptions: .weakMemory, valueOptions: .strongMemory)

    init(rootView: NSView) {
        self.rootView = rootView
    }

    var hasActiveCaches: Bool {
        structureViewsByInvalidator.keyEnumerator().nextObject() != nil
    }

    func add(_ invalidator: PortalSplitDividerCacheInvalidator, structureViews: [NSView]) {
        let observedViews = NSHashTable<NSView>.weakObjects()
        for view in structureViews {
            observedViews.add(view)
        }
        structureViewsByInvalidator.setObject(observedViews, forKey: invalidator)
    }

    func remove(_ invalidator: PortalSplitDividerCacheInvalidator) {
        structureViewsByInvalidator.removeObject(forKey: invalidator)
    }

    func observesStructure(of view: NSView) -> Bool {
        let enumerator = structureViewsByInvalidator.objectEnumerator()
        while let observedViews = enumerator?.nextObject() as? NSHashTable<NSView> {
            if observedViews.contains(view) { return true }
        }
        return false
    }

    func notify() {
        guard let rootView else { return }
        let invalidators = structureViewsByInvalidator.keyEnumerator().allObjects.compactMap {
            $0 as? PortalSplitDividerCacheInvalidator
        }
        for invalidator in invalidators {
            invalidator.viewHierarchyDidMutate(in: rootView)
        }
    }
}
