public import AppKit

/// Drags from outside into the hosted page (task 050 of plans/cmux-next/chrome-parity/p01-process.md):
/// this view's `NSDraggingDestination` methods feed ``ChromiumHostDragDestination``, as
/// `RenderWidgetHostViewCocoa`'s feed Chrome's `WebDragDest`. With ``InputTarget/pageWindow`` the
/// view takes no events: the pane's `CEFHostView` takes the drag and hands it to the same
/// destination (`CEFFileDragRelay.pageDestination`).
extension ChromiumHostPageView {
    /// Makes this view's page take drags through `wire`; nil takes none.
    func takeDrags(through wire: (any ChromiumHostDragWire)?) {
        dragDestination.wire = wire
        if wire != nil, inputTarget == .view {
            registerForDraggedTypes(ChromiumHostDropData.types)
        } else {
            unregisterDraggedTypes()
        }
    }

    /// The drags this page view sent through Chromium's DragTarget calls (`debug.cef`'s `page_drag`).
    public var dragCounts: ChromiumHostDragCounts {
        var counts = dragDestination.counts
        counts.takesDrags = dragDestination.wire != nil
        return counts
    }

    public override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        dragDestination.entered(ChromiumHostDropData(pasteboard: sender.draggingPasteboard), at: dragPoint(sender),
                                allowed: sender.draggingSourceOperationMask, modifiers: Self.dragModifiers())
    }

    public override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        dragDestination.updated(at: dragPoint(sender), allowed: sender.draggingSourceOperationMask, modifiers: Self.dragModifiers())
    }

    public override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        dragDestination.exited()
    }

    public override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        dragDestination.dropped(at: dragPoint(sender), modifiers: Self.dragModifiers())
    }

    /// A session that ended with no exit or drop here (the view left its window mid-drag).
    // NSView has no `draggingEnded:` of its own: no super call.
    public override func draggingEnded(_ sender: any NSDraggingInfo) {
        dragDestination.exited()
    }

    /// The drag's location in the page: view points from the top left.
    private func dragPoint(_ sender: any NSDraggingInfo) -> ChromiumHostDragPoint {
        ChromiumHostDragPoint(unflipped: convert(sender.draggingLocation, from: nil), height: bounds.height)
    }

    /// The held keys and buttons now, as `cef_event_flags_t`.
    static func dragModifiers() -> Int32 {
        ChromiumHostDragDestination.modifiers(NSEvent.modifierFlags, pressedButtons: NSEvent.pressedMouseButtons)
    }
}
