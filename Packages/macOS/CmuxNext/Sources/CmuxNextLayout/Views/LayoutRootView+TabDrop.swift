public import AppKit

/// Tab drops: the in-process drag API for tab strips that track the mouse
/// themselves, and the AppKit `NSDraggingDestination` path.
extension LayoutRootView {
    /// Updates the drop highlight for an in-process tab drag (for tab strips
    /// that track the mouse themselves instead of using NSDraggingSession).
    @discardableResult
    public func updateTabDrag(_ tab: TabID, locationInWindow: NSPoint) -> DropTarget? {
        dragTab = tab
        guard let active = model.activeScreenID, let view = screenViews[active] else {
            hideHighlight()
            return nil
        }
        let local = view.convert(locationInWindow, from: nil)
        guard let hit = view.dropTarget(at: local) else {
            hideHighlight()
            return nil
        }
        let rect = convert(hit.highlight, from: view)
        if highlight.show(rect, text: LayoutStrings.label(for: hit.target), animated: canAnimate) { driver.start() }
        return hit.target
    }

    /// Ends a tab drag. Emits `.dropTab` when over a target and returns it.
    @discardableResult
    public func endTabDrag(_ tab: TabID, locationInWindow: NSPoint) -> DropTarget? {
        let target = updateTabDrag(tab, locationInWindow: locationInWindow)
        hideHighlight()
        dragTab = nil
        if let target { model.dropTab(tab, on: target) }
        return target
    }

    public func cancelTabDrag() {
        dragTab = nil
        hideHighlight()
    }

    func hideHighlight() {
        if highlight.hide(animated: canAnimate) { driver.start() }
    }

    // MARK: NSDraggingDestination

    private func tabID(from info: any NSDraggingInfo) -> TabID? {
        info.draggingPasteboard.string(forType: LayoutTabDrag.pasteboardType).map(TabID.init(rawValue:))
    }

    override public func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        draggingUpdated(sender)
    }

    override public func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard let tab = tabID(from: sender), updateTabDrag(tab, locationInWindow: sender.draggingLocation) != nil else {
            hideHighlight()
            return []
        }
        return .move
    }

    override public func draggingExited(_ sender: (any NSDraggingInfo)?) {
        cancelTabDrag()
    }

    override public func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard let tab = tabID(from: sender) else { return false }
        return endTabDrag(tab, locationInWindow: sender.draggingLocation) != nil
    }

    override public func concludeDragOperation(_ sender: (any NSDraggingInfo)?) {
        cancelTabDrag()
    }
}
