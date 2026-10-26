public import AppKit

/// A drag the page view's page started, from its session's start to its end (task 051).
struct ChromiumHostPageDrag {
    let data: CEFPageDragData
    /// The page's browser: back over the view, the drag is the page's own only while the view still shows it.
    let browser: Int32
    /// Ends the page's drag (`cmux_shim_browser_drag_source_ended`): where (page view and screen points, both from
    /// the top left) and the operation the destination took (none: no drop took it).
    let ended: (_ point: CGPoint, _ screen: CGPoint, _ operation: NSDragOperation) -> Void
    /// The session's `draggingSequenceNumber`: only that session counts as the page's own drag.
    var sequence = 0
}

/// Drags into and out of the hosted page (tasks 050 and 051 of plans/cmux-next/chrome-parity/p01-process.md).
///
/// Into the page: this view's `NSDraggingDestination` methods feed ``ChromiumHostDragDestination``, as
/// `RenderWidgetHostViewCocoa`'s feed Chrome's `WebDragDest`. With ``InputTarget/pageWindow`` the view takes no
/// events: the pane's `CEFHostView` takes the drag and hands it to the same methods
/// (`CEFFileDragRelay.hostedPage`).
///
/// Out of the page: in host mode Chromium's page window never shows, so a page's drag cannot start from it. The
/// host sends the drag's data (DRAG_START) and this view starts the session, as Chrome's app shim view does with
/// the drag its browser process sends (content/app_shim_remote_cocoa/web_contents_view_cocoa.mm,
/// `-startDragWithDropData:`), and reports the end back (`WebDragSource`'s `-endDragAt:operation:`,
/// content/app_shim_remote_cocoa/web_drag_source_mac.mm). Back over this view the session is the page's own drag:
/// the destination enters it with `cmux_shim_browser_drag_target_enter_source`, so the page keeps its custom drag
/// data, and then goes on as for any drag, with the page's answers.
extension ChromiumHostPageView: NSDraggingSource {
    /// The pasteboard type that names a drag of a hosted page; the view takes drags carrying it.
    static let pageDragType = NSPasteboard.PasteboardType("com.cmuxterm.chromium-page-drag")

    /// Makes this view's page take drags through `wire`; nil takes none. `outside` false takes only the page's own
    /// drag back over it (feature `chromiumHostDragOut` without `chromiumHostDragIn`).
    func takeDrags(through wire: (any ChromiumHostDragWire)?, outside: Bool = true) {
        dragDestination.wire = wire
        dragDestination.takesOutsideDrags = outside
        if wire != nil, inputTarget == .view {
            registerForDraggedTypes(Self.dragTypes(outside: outside))
        } else {
            unregisterDraggedTypes()
        }
    }

    /// The pasteboard types a page view (or the pane's host view for it) takes: the page's own drag, and with
    /// `outside` the types a page takes from any drag.
    static func dragTypes(outside: Bool) -> [NSPasteboard.PasteboardType] {
        (outside ? ChromiumHostDropData.types : []) + [pageDragType]
    }

    /// The drags this page view sent through Chromium's DragTarget calls and the page drags it started
    /// (`debug.cef`'s `page_drag`).
    public var dragCounts: ChromiumHostDragCounts {
        var counts = dragDestination.counts
        counts.takesDrags = dragDestination.wire != nil
        counts.sessions = pageDragSessions
        counts.lastSessionOperation = lastPageDragOperation.map { Int($0.rawValue) }
        return counts
    }

    // MARK: The drag's destination

    public override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        if let drag = ownDrag(sender) {
            return dragDestination.enteredSource(browser: drag.browser, at: dragPoint(sender), allowed: sender.draggingSourceOperationMask,
                                                 initial: drag.data.preferredOperation, modifiers: Self.dragModifiers())
        }
        return dragDestination.entered(ChromiumHostDropData(pasteboard: sender.draggingPasteboard), at: dragPoint(sender),
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

    /// The page's drag that `sender` is, nil for any other drag.
    private func ownDrag(_ sender: any NSDraggingInfo) -> ChromiumHostPageDrag? {
        guard let drag = pageDrag, sender.draggingSequenceNumber == drag.sequence,
              (sender.draggingSource as AnyObject?) === self else { return nil }
        return drag
    }

    /// The drag's location in the page: view points from the top left.
    private func dragPoint(_ sender: any NSDraggingInfo) -> ChromiumHostDragPoint {
        ChromiumHostDragPoint(unflipped: convert(sender.draggingLocation, from: nil), height: bounds.height)
    }

    /// The held keys and buttons now, as `cef_event_flags_t`.
    static func dragModifiers() -> Int32 {
        ChromiumHostDragDestination.modifiers(NSEvent.modifierFlags, pressedButtons: NSEvent.pressedMouseButtons)
    }

    // MARK: The page's drag out

    /// Starts the session for a drag `browser`'s page started; false (nothing started) when the view is in no
    /// window or the person already let go of the button, so the caller ends the page's drag at once. `ended`
    /// reports the session's end (``ChromiumHostPageDrag/ended``).
    func beginPageDrag(_ data: CEFPageDragData, browser: Int32,
                       ended: @escaping (_ point: CGPoint, _ screen: CGPoint, _ operation: NSDragOperation) -> Void) -> Bool {
        guard pageDrag == nil, let window, NSEvent.pressedMouseButtons & 1 != 0 else { return false }
        // The drag comes after the page's mouse moves, so the current event need not be a drag: Chrome makes
        // one at the pointer for the same reason (`-startDragWithDropData:`).
        let location = window.mouseLocationOutsideOfEventStream
        guard let event = NSEvent.mouseEvent(with: .leftMouseDragged, location: location, modifierFlags: NSEvent.modifierFlags,
                                             timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                             context: nil, eventNumber: 0, clickCount: 1, pressure: 1) else { return false }
        let item = NSDraggingItem(pasteboardWriter: data.pasteboardWriter(marker: Self.pageDragType))
        let image = Self.dragImage(data)
        item.setDraggingFrame(Self.draggingFrame(image: image?.size ?? .zero, offset: data.cursorOffset,
                                                 pointer: convert(location, from: nil)), contents: image)
        pageDrag = ChromiumHostPageDrag(data: data, browser: browser, ended: ended)
        pageDrag?.sequence = beginDraggingSession(with: [item], event: event, source: self).draggingSequenceNumber
        pageDragSessions += 1
        return true
    }

    /// The page's PNG at its own scale; nil when it sent none (AppKit then shows no image).
    static func dragImage(_ data: CEFPageDragData) -> NSImage? {
        guard !data.imagePNG.isEmpty, let rep = NSBitmapImageRep(data: data.imagePNG), rep.pixelsWide > 0,
              rep.pixelsHigh > 0 else { return nil }
        let image = NSImage(size: NSSize(width: CGFloat(rep.pixelsWide) / data.imageScale,
                                         height: CGFloat(rep.pixelsHigh) / data.imageScale))
        image.addRepresentation(rep)
        return image
    }

    /// The image's frame in this unflipped view: its top left `offset` (from the top left) away from the pointer.
    static func draggingFrame(image size: CGSize, offset: CGPoint, pointer: CGPoint) -> CGRect {
        CGRect(x: pointer.x - offset.x, y: pointer.y + offset.y - size.height, width: size.width, height: size.height)
    }

    public func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        pageDrag?.data.allowedOperations ?? []
    }

    public func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        guard let drag = pageDrag, session.draggingSequenceNumber == drag.sequence else { return }
        pageDrag = nil
        let taken = operation.intersection(drag.data.allowedOperations)
        lastPageDragOperation = taken
        let local = window.map { convert($0.convertPoint(fromScreen: screenPoint), from: nil) } ?? .zero
        // Screen points from the top of the window's screen, as WebDragSource flips them.
        let screenHeight = window?.screen?.frame.height ?? NSScreen.screens.first?.frame.height ?? 0
        drag.ended(CGPoint(x: local.x, y: bounds.height - local.y), CGPoint(x: screenPoint.x, y: screenHeight - screenPoint.y), taken)
    }
}
