public import AppKit

/// Where a page's drag reports to: the shim calls for its browser (``CEFRuntime/pageDragRoute(browser:)``).
/// Points are the page view's, from its top left; modifiers are `cef_event_flags_t`.
struct ChromiumHostPageDragRoute {
    /// The session ended: where (page view and screen points, the screen's from its top left) and the
    /// operation the destination took (none: no drop took it). `cmux_shim_browser_drag_source_ended`.
    var ended: (_ point: CGPoint, _ screen: CGPoint, _ operation: NSDragOperation) -> Void
    /// The drag came back over its own page: false when the page is no longer this view's.
    /// `cmux_shim_browser_drag_target_enter_source`.
    var entered: (_ x: Int32, _ y: Int32, _ allowed: NSDragOperation, _ modifiers: Int32) -> Bool
    var moved: (_ x: Int32, _ y: Int32, _ allowed: NSDragOperation, _ modifiers: Int32) -> Void
    var left: () -> Void
    var dropped: (_ x: Int32, _ y: Int32, _ modifiers: Int32) -> Void
}

/// A drag the page view's page started, from its session's start to its end.
struct ChromiumHostPageDrag {
    let data: CEFPageDragData
    let route: ChromiumHostPageDragRoute
    /// The session's `draggingSequenceNumber`: only that session counts as the page's own drag.
    var sequence = 0
    /// The session is over the page view, entered as the page's own drag.
    var isOverPage = false
    /// The last move sent to the page (AppKit repeats updates while the pointer rests).
    var lastMove: [Int32]?
    /// The page's answer to the last move, once the fork pushes it (`cmux_browser_drag_target_watch`,
    /// tasks 172 and 178); until then ``CEFPageDragData/preferredOperation``.
    var pageOperation: NSDragOperation?

    var operation: NSDragOperation { pageOperation ?? data.preferredOperation }
}

/// Dragging out of a hosted page (task 051 of plans/cmux-next/chrome-parity/p01-process.md).
///
/// In host mode Chromium's page window never shows, so a page's drag cannot start from it: the host sends
/// the drag's data (DRAG_START) and this view starts the session, as Chrome's app shim view does with the
/// drag its browser process sends (content/app_shim_remote_cocoa/web_contents_view_cocoa.mm,
/// `-startDragWithDropData:`), and reports the end back (`WebDragSource`'s `-endDragAt:operation:`,
/// content/app_shim_remote_cocoa/web_drag_source_mac.mm). The session starts over its own page, and the page
/// is its first drop target: back over this view it goes on as the page's own drag
/// (`cmux_shim_browser_drag_target_enter_source`), so the page keeps its custom drag data, as Chrome's
/// WebDragDest does for a drag from the same contents.
extension ChromiumHostPageView: NSDraggingSource {
    /// The pasteboard type that names a drag of a hosted page; the view takes drags carrying it.
    static let pageDragType = NSPasteboard.PasteboardType("com.cmuxterm.chromium-page-drag")

    /// Starts the session for a drag the page started; false (nothing started) when the view is in no window
    /// or the person already let go of the button, so the caller ends the page's drag at once.
    func beginPageDrag(_ data: CEFPageDragData, route: ChromiumHostPageDragRoute) -> Bool {
        guard pageDrag == nil, let window, NSEvent.pressedMouseButtons & 1 != 0 else { return false }
        // The drag comes after the page's mouse moves, so the current event need not be a drag: Chrome makes
        // one at the pointer for the same reason (`-startDragWithDropData:`).
        let location = window.mouseLocationOutsideOfEventStream
        guard let event = NSEvent.mouseEvent(with: .leftMouseDragged, location: location, modifierFlags: NSEvent.modifierFlags,
                                             timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                             context: nil, eventNumber: 0, clickCount: 1, pressure: 1) else { return false }
        registerForDraggedTypes([Self.pageDragType])
        let item = NSDraggingItem(pasteboardWriter: data.pasteboardWriter(marker: Self.pageDragType))
        let image = Self.dragImage(data)
        item.setDraggingFrame(Self.draggingFrame(image: image?.size ?? .zero, offset: data.cursorOffset,
                                                 pointer: convert(location, from: nil)), contents: image)
        pageDrag = ChromiumHostPageDrag(data: data, route: route)
        pageDrag?.sequence = beginDraggingSession(with: [item], event: event, source: self).draggingSequenceNumber
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
        let local = window.map { convert($0.convertPoint(fromScreen: screenPoint), from: nil) } ?? .zero
        // Screen points from the top of the window's screen, as WebDragSource flips them.
        let screenHeight = window?.screen?.frame.height ?? NSScreen.screens.first?.frame.height ?? 0
        drag.route.ended(CGPoint(x: local.x, y: bounds.height - local.y), CGPoint(x: screenPoint.x, y: screenHeight - screenPoint.y),
                         operation.intersection(drag.data.allowedOperations))
    }

    // MARK: The page's own drag over the page

    /// The page's drag that `sender` is, nil for any other drag.
    private func ownDrag(_ sender: any NSDraggingInfo) -> ChromiumHostPageDrag? {
        guard let drag = pageDrag, sender.draggingSequenceNumber == drag.sequence,
              (sender.draggingSource as AnyObject?) === self else { return nil }
        return drag
    }

    /// The drag's place in the page: points from the top left.
    private func pageDragPoint(_ sender: any NSDraggingInfo) -> (x: Int32, y: Int32) {
        let local = convert(sender.draggingLocation, from: nil)
        return (Int32(local.x.rounded(.down)), Int32((bounds.height - local.y).rounded(.down)))
    }

    public override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard let drag = ownDrag(sender) else { return [] }
        let point = pageDragPoint(sender)
        let allowed = sender.draggingSourceOperationMask.intersection(drag.data.allowedOperations)
        let modifiers = Self.cefModifiers(NSEvent.modifierFlags)
        guard drag.route.entered(point.x, point.y, allowed, modifiers) else { return [] }
        pageDrag?.isOverPage = true
        pageDrag?.lastMove = [point.x, point.y, Int32(clamping: allowed.rawValue), modifiers]
        return drag.operation.intersection(allowed)
    }

    public override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard let drag = ownDrag(sender), drag.isOverPage else { return [] }
        let point = pageDragPoint(sender)
        let allowed = sender.draggingSourceOperationMask.intersection(drag.data.allowedOperations)
        let modifiers = Self.cefModifiers(NSEvent.modifierFlags)
        let move = [point.x, point.y, Int32(clamping: allowed.rawValue), modifiers]
        if move != drag.lastMove {
            pageDrag?.lastMove = move
            drag.route.moved(point.x, point.y, allowed, modifiers)
        }
        return drag.operation.intersection(allowed)
    }

    public override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        leavePage()
    }

    public override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard let drag = ownDrag(sender), drag.isOverPage else { return false }
        let point = pageDragPoint(sender)
        pageDrag?.isOverPage = false
        drag.route.dropped(point.x, point.y, Self.cefModifiers(NSEvent.modifierFlags))
        return true
    }

    /// The session ended over this view with no exit or drop here (the view left its window mid-drag).
    // NSView has no `draggingEnded:` of its own: no super call.
    public override func draggingEnded(_ sender: any NSDraggingInfo) {
        leavePage()
    }

    private func leavePage() {
        guard let drag = pageDrag, drag.isOverPage else { return }
        pageDrag?.isOverPage = false
        pageDrag?.lastMove = nil
        drag.route.left()
    }

    /// `cef_event_flags_t` of the held modifier keys and the left button (the drag holds it).
    static func cefModifiers(_ flags: NSEvent.ModifierFlags) -> Int32 {
        var bits: Int32 = 1 << 4  // EVENTFLAG_LEFT_MOUSE_BUTTON
        if flags.contains(.capsLock) { bits |= 1 << 0 }
        if flags.contains(.shift) { bits |= 1 << 1 }
        if flags.contains(.control) { bits |= 1 << 2 }
        if flags.contains(.option) { bits |= 1 << 3 }
        if flags.contains(.command) { bits |= 1 << 7 }
        return bits
    }
}
