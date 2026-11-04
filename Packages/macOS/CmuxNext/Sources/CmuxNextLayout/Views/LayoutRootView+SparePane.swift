public import AppKit

extension LayoutRootView {
    /// Parks the provider's next stand-in pane content in a pane host made now, hidden in this view and so already in the
    /// window: the key that opens a pane (New Column, New Row, Cmd-D) adopts both and puts no new view in the window
    /// (TERMINAL CREATE COST item 4). Call it only while the layout is still; nil drops the one parked.
    public func parkSparePaneContent(_ content: NSView?) {
        if content != nil, context.spareShelf.superview !== self { addSubview(context.spareShelf, positioned: .below, relativeTo: nil) }
        context.parkSpare(content)
    }

    /// Parks `spare`'s pane view (``parkSparePaneContent(_:)``) and returns `spare`.
    public func parkingSpare<Spare, View: NSView>(_ spare: Spare, view: KeyPath<Spare, View>) -> Spare {
        parkSparePaneContent(spare[keyPath: view])
        return spare
    }
}
