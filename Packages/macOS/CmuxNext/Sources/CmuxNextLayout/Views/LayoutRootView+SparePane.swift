public import AppKit

extension LayoutRootView {
    /// Parks the provider's next stand-in pane content in a pane host made now, hidden in the active screen's view and so
    /// already in the window: the key that opens a pane there (New Column, New Row, Cmd-D) only unhides it, with no view
    /// moving into the window or between superviews (TERMINAL CREATE COST item 4). Call it only while the layout is still;
    /// nil drops the one parked. With no screen view yet, nothing is parked (the pane's host is made in its key's turn).
    public func parkSparePaneContent(_ content: NSView?) {
        context.parkSpare(content, in: model.activeScreenID.flatMap { screenViews[$0] })
    }

    /// Parks `spare`'s pane view (``parkSparePaneContent(_:)``) and returns `spare`.
    public func parkingSpare<Spare, View: NSView>(_ spare: Spare, view: KeyPath<Spare, View>) -> Spare {
        parkSparePaneContent(spare[keyPath: view])
        return spare
    }
}
