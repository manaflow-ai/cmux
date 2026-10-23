public import AppKit

/// The pointing hand over a clickable view while another window of the app has the key (a
/// Chromium page's child window), where its cursor rects do nothing (the sidebar's New Workspace
/// button, the titlebar's sidebar toggle).
///
/// A tracking area (in the active app, over the visible rect) sets the hand on enter and on every
/// move, after reading the pointer again (what shows of the view, in the top window under the
/// pointer); never over a hidden or disabled view. In the key window, and inside a
/// `ClickableCursorHost` (the browser toolbar row sets the cursor itself), it sets nothing. The
/// tracking area's owner is this object, so its events never reach the view.
///
/// Cost per pointer move over a tracked view: local reads first (the pointer, the view's
/// geometry, the key window, enabled and hidden). The window list (`topWindowNumber`, a
/// WindowServer round trip) is read only when another window has the key and the pointer is
/// over an enabled tracked view, once per such move.
///
/// One owner: `owner` is the tracker whose hand shows. Another tracker that sets its hand takes
/// it, so an exit that AppKit delivers after the next enter leaves the next view's hand alone. A
/// tracker clears the hand (the arrow) only while it is the owner, the hand still shows, the
/// pointer is still in its window (the top window under it, so an exit a menu's tracking loop
/// swallowed never puts the arrow over the page's own hand later), and no other enabled
/// `ClickableButton` is under the pointer (its enter, still to come, keeps the hand).
///
/// A still pointer: the key child window resets the cursor in its display cycle (a page reload),
/// with no event for the tracker. `keepHand()`, called by the main run loop's cursor keeper
/// (`ArrowCursorView`) after each pass and after each pointer move, sets the owner's hand again.
/// Each pass also reads the pointer against the owner's geometry, so an exit that never came (a
/// menu swallowed it, the view collapsed or scrolled away under a still pointer) releases it.
/// A child window can also take the key while the pointer rests on a button whose own window had
/// it (`waiting`, the rects showed the hand); the keeper's next pass gives that button the hand.
@MainActor
public final class ClickableCursorTracker: NSResponder {
    /// The tracker whose hand shows now; nil when none does. Tests clear it before each case.
    static weak var owner: ClickableCursorTracker?
    /// The tracker the pointer rests on while its own window has the key and it would otherwise
    /// show the hand; nil when none does. `keepHand()` promotes it once another window has the key.
    static weak var waiting: ClickableCursorTracker?

    private weak var view: NSView?
    private let isClickable: @MainActor () -> Bool
    private var area: NSTrackingArea?
    /// The pointer entered the view and has not left it (no exit, hide or window change since).
    private(set) var inside = false

    // Tests replace these (a test host has no real pointer, key window or window list).
    var isKey: @MainActor (NSWindow) -> Bool = { $0.isKeyWindow }
    var mouseLocation: @MainActor () -> NSPoint = { NSEvent.mouseLocation }
    var topWindowNumber: @MainActor (NSPoint) -> Int = { NSWindow.windowNumber(at: $0, belowWindowWithWindowNumber: 0) }
    var setCursor: @MainActor (NSCursor) -> Void = { $0.set() }
    var currentCursor: @MainActor () -> NSCursor? = { NSCursor.current }

    public init(_ view: NSView, isClickable: @escaping @MainActor () -> Bool) {
        self.view = view
        self.isClickable = isClickable
        super.init()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Whether this tracker's hand shows now.
    var showsHand: Bool { Self.owner === self }

    /// Adds the tracking area once; `.inVisibleRect` keeps it on the view's visible rect.
    public func install() {
        guard area == nil, let view else { return }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeInActiveApp, .inVisibleRect],
                                  owner: self)
        view.addTrackingArea(area)
        self.area = area
    }

    override public func mouseEntered(with event: NSEvent) { pointerEntered() }
    override public func mouseMoved(with event: NSEvent) { pointerMoved() }
    override public func mouseExited(with event: NSEvent) { pointerExited() }

    func pointerEntered() {
        inside = true
        update()
    }

    func pointerMoved() {
        inside = true
        update()
    }

    func pointerExited() {
        leave()
    }

    /// The view was enabled or disabled: under a still pointer the cursor follows at once.
    public func clickableStateDidChange() {
        guard inside else { return }
        update()
    }

    /// The view hides or changes window under a still pointer, with no exit event.
    public func viewWillLeave() {
        leave()
    }

    /// After a run loop pass or a pointer move. Two reads while no tracker shows its hand or waits
    /// for the key. While the hand shows: the pointer against the owner's geometry and its state
    /// (local reads, no window list), then one cursor comparison. The pointer off the view, or the
    /// view collapsed, clipped away, hidden or disabled, releases the hand (`release()`, which
    /// reads the window list once). Another cursor showing (the key child window's reset) gets the
    /// hand again after one window-list read. A waiting tracker whose window lost the key is
    /// updated once.
    public static func keepHand() {
        if owner == nil, let waiting, let window = waiting.view?.window, !waiting.isKey(window) {
            Self.waiting = nil
            if waiting.inside { waiting.update() }
            return
        }
        guard let owner else { return }
        guard owner.inside, owner.pointerOverViewGeometry(), owner.handAllowed() else {
            owner.inside = false
            return owner.release()
        }
        guard owner.currentCursor() !== NSCursor.pointingHand else { return }
        guard owner.pointerInTopWindow() else {
            owner.inside = false
            return owner.release()
        }
        owner.setCursor(.pointingHand)
    }

    /// Local reads first; the window list only while another window has the key and the pointer
    /// is over this enabled view.
    private func update() {
        guard let window = view?.window, pointerOverViewGeometry() else {
            inside = false
            stopWaiting()
            return release()
        }
        guard handAllowed(ignoringKey: true) else {
            stopWaiting()
            return release()
        }
        if isKey(window) {
            // The key window's cursor rects show the hand; a child window may take the key later.
            Self.waiting = self
            return release()
        }
        stopWaiting()
        guard pointerInTopWindow() else {
            inside = false
            return release()
        }
        Self.owner = self
        setCursor(.pointingHand)
    }

    private func stopWaiting() {
        if Self.waiting === self { Self.waiting = nil }
    }

    private func leave() {
        inside = false
        stopWaiting()
        release()
    }

    /// The hand goes only while this tracker owns it. The arrow replaces it only while another
    /// window has the key (the key window's rects decide), the hand still shows (no other view set
    /// its cursor), the pointer is in this view's window as the top window under it (not over the
    /// page, where the page set its own cursor), and no other enabled `ClickableButton` is under it.
    private func release() {
        guard showsHand else { return }
        Self.owner = nil
        guard let window = view?.window, !isKey(window), currentCursor() === NSCursor.pointingHand,
              let point = ClickableButton.pointer(in: window, screenPoint: mouseLocation(), topWindowNumber: topWindowNumber),
              !Self.enabledClickableButton(at: point, in: window, excluding: view) else { return }
        setCursor(.arrow)
    }

    private func handAllowed(ignoringKey: Bool = false) -> Bool {
        guard let view, let window = view.window, ignoringKey || !isKey(window), !Self.hasHost(view) else { return false }
        return isClickable() && !view.isHiddenOrHasHiddenAncestor
    }

    /// An enabled `ClickableButton` other than `own` (outside a `ClickableCursorHost`) is the view
    /// under the window point, or one of its ancestors.
    private static func enabledClickableButton(at point: NSPoint, in window: NSWindow, excluding own: NSView?) -> Bool {
        guard let content = window.contentView,
              let hit = content.hitTest(content.superview?.convert(point, from: nil) ?? point) else { return false }
        var candidate: NSView? = hit
        while let current = candidate {
            if let button = current as? ClickableButton {
                return button !== own && button.isEnabled && !button.isHiddenOrHasHiddenAncestor && !hasHost(button)
            }
            candidate = current.superview
        }
        return false
    }

    /// The pointer is over what shows of the view (`ClickableButton.cursorRect(of:)`), from local
    /// reads only: no window list, so another window may still cover that point.
    private func pointerOverViewGeometry() -> Bool {
        guard let view, let window = view.window, let rect = ClickableButton.cursorRect(of: view) else { return false }
        return rect.contains(view.convert(window.convertPoint(fromScreen: mouseLocation()), from: nil))
    }

    /// The view's window is the top window under the pointer (one window-list read).
    private func pointerInTopWindow() -> Bool {
        guard let window = view?.window else { return false }
        return ClickableButton.pointer(in: window, screenPoint: mouseLocation(), topWindowNumber: topWindowNumber) != nil
    }

    private static func hasHost(_ view: NSView) -> Bool {
        var ancestor = view.superview
        while let current = ancestor {
            if current is any ClickableCursorHost { return true }
            ancestor = current.superview
        }
        return false
    }
}
