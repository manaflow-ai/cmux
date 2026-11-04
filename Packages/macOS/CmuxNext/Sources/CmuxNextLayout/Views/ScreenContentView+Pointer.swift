import AppKit

/// The pointer over a screen's dividers: one tracking area on the screen view, which does not move, hit-tests the
/// current handle frames for the hover and the resize cursor (`ScreenDividers.refreshHover`), as Chrome sets the cursor
/// from the hit test of each mouse event. The handles have no tracking areas and no cursor rects: AppKit moves those
/// with a view's frame, and each move rebuilt the window's structural regions (drag margins and a constraint min-size
/// walk of every view) in that display cycle, while a spring or a drag moves dividers in every frame (HOT PATH AUDIT
/// frames, DividerCursorNoRegionRebuildTests). This object owns that tracking area, so its events come here and never
/// mix with the screen's responder chain (a subview's move passed up to the layout root's pane hover).
@MainActor
final class ScreenDividerPointer: NSResponder {
    private weak var screen: ScreenContentView?
    private var trackingArea: NSTrackingArea?
    /// The resize cursor this screen set last (its hover, or a handle's `cursorUpdate`); nil while it shows none.
    private(set) var shownCursor: NSCursor?

    /// A handle answered AppKit's `cursorUpdate` with its resize cursor: the screen gives it back when the pointer
    /// leaves the dividers or the screen hides, as for its own.
    func handleDidShow(_ cursor: NSCursor) { shownCursor = cursor }

    init(screen: ScreenContentView) {
        self.screen = screen
        super.init()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// The screen's tracking areas are being rebuilt (`updateTrackingAreas`): one area over its visible rect.
    func installTrackingArea(in view: NSView) {
        if let trackingArea { view.removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow, .inVisibleRect],
                                  owner: self)
        view.addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { refresh(event, windowsChanged: true) }
    override func mouseExited(with event: NSEvent) { refresh(event, windowsChanged: true) }
    override func mouseMoved(with event: NSEvent) { refresh(event, windowsChanged: false) }

    private func refresh(_ event: NSEvent, windowsChanged: Bool) {
        guard let screen else { return }
        // Where it entered or left, the windows over the pointer may differ: the window server is asked again.
        if windowsChanged { screen.context.invalidateHoverTopmost() }
        ScreenDividers(screen: screen).refreshHover(event: event)
    }

    /// Shows `handle`'s resize cursor, or gives the cursor back when the pointer left the last one. With no event (the
    /// handles moved under a still pointer) only a change sets it; a pointer event sets it every time, after whatever
    /// AppKit's cursor rects of the views around set for the same move. `pointer` (window coordinates) is the one the
    /// hover hit test read (the real pointer, or `debug.mouse`'s).
    func show(_ handle: DividerHandleView?, in screen: NSView, pointer: NSPoint?, event: NSEvent?) {
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
        // The view under the pointer shows its own cursor again: AppKit reads its cursor rects again for this one change.
        guard let window = screen.window, let content = window.contentView else { return }
        let point = event?.locationInWindow ?? pointer ?? window.mouseLocationOutsideOfEventStream
        guard let hit = content.hitTest(content.superview?.convert(point, from: nil) ?? point), hit !== screen,
              !(hit is DividerHandleView) else { return }
        window.invalidateCursorRects(for: hit)
    }
}

extension ScreenContentView {
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        dividerPointer.installTrackingArea(in: self)
    }

    /// Hidden (itself or an ancestor: a workspace switch): it gets no pointer events now, so it gives its cursor back.
    override func viewDidHide() {
        super.viewDidHide()
        refreshDividerHover()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { dividerPointer.show(nil, in: self, pointer: nil, event: nil) }
        super.viewWillMove(toWindow: newWindow)
    }

    /// In a window: the divider tracking area goes on at once. AppKit calls `updateTrackingAreas` when tracking areas
    /// need recomputing, not for a view that has none yet (px-divider-hover: the pointer on a divider got no event).
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { dividerPointer.installTrackingArea(in: self) }
    }
}
