import AppKit

/// The pointer over a screen's dividers: one tracking area on the screen view, which does not move, hit-tests the
/// current handle frames for the hover and the resize cursor (`ScreenDividers.refreshHover`), as Chrome sets the cursor
/// from the hit test of each mouse event. The handles have no tracking areas and no cursor rects: AppKit moves those
/// with a view's frame, and each move rebuilt the window's structural regions (drag margins and a constraint min-size
/// walk of every view) in that display cycle, while a spring or a drag moves dividers in every frame (HOT PATH AUDIT
/// frames, DividerCursorNoRegionRebuildTests).
@MainActor
final class ScreenDividerPointer {
    fileprivate var trackingArea: NSTrackingArea?
    /// The resize cursor this screen set last; nil while it shows none.
    private(set) var shownCursor: NSCursor?

    /// Shows `handle`'s resize cursor, or gives the cursor back when the pointer left the last one. With no event (the
    /// handles moved under a still pointer) only a change sets it; a pointer event sets it every time, after whatever
    /// AppKit's cursor rects of the views around set for the same move.
    func show(_ handle: DividerHandleView?, in screen: NSView, event: NSEvent?) {
        if let handle {
            let cursor = handle.resizeCursor
            guard event != nil || shownCursor != cursor else { return }
            cursor.set()
            shownCursor = cursor
            return
        }
        guard shownCursor != nil else { return }
        shownCursor = nil
        NSCursor.arrow.set()
        // The view under the pointer shows its own cursor again: from this event, or (a still pointer) from its
        // cursor rects, read again once for this one change.
        guard let window = screen.window, let content = window.contentView else { return }
        let point = event?.locationInWindow ?? window.mouseLocationOutsideOfEventStream
        guard let hit = content.hitTest(content.superview?.convert(point, from: nil) ?? point), hit !== screen,
              !(hit is DividerHandleView) else { return }
        if let event { hit.cursorUpdate(with: event) } else { window.invalidateCursorRects(for: hit) }
    }
}

extension ScreenContentView {
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area = dividerPointer.trackingArea { removeTrackingArea(area) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow, .inVisibleRect],
                                  owner: self)
        addTrackingArea(area)
        dividerPointer.trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        guard isDividerPointerEvent(event) else { return super.mouseEntered(with: event) }
        context.invalidateHoverTopmost() // The windows over the pointer may differ where it entered.
        ScreenDividers(screen: self).refreshHover(event: event)
    }

    override func mouseExited(with event: NSEvent) {
        guard isDividerPointerEvent(event) else { return super.mouseExited(with: event) }
        context.invalidateHoverTopmost()
        ScreenDividers(screen: self).refreshHover(event: event)
    }

    override func mouseMoved(with event: NSEvent) {
        // The root tracks its own moves (pane focus on hover): this area's moves stop here.
        guard isDividerPointerEvent(event) else { return super.mouseMoved(with: event) }
        ScreenDividers(screen: self).refreshHover(event: event)
    }

    /// This screen's divider tracking area sent `event`; a subview's event that came up the responder chain goes on.
    private func isDividerPointerEvent(_ event: NSEvent) -> Bool {
        event.trackingArea != nil && event.trackingArea === dividerPointer.trackingArea
    }
}
