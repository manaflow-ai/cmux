public import AppKit

/// The pointing hand over a clickable view while another window of the app has the key (a
/// Chromium page's child window), where its cursor rects do nothing (the sidebar's New Workspace
/// button, the titlebar's sidebar toggle).
///
/// A tracking area (in the active app, over the visible rect) sets the hand on enter and on every
/// move, after reading the pointer again (the view's visible rect, in the top window under the
/// pointer); never over a hidden or disabled view. In the key window, and inside a
/// `ClickableCursorHost` (the browser toolbar row sets the cursor itself), it sets nothing. The
/// tracking area's owner is this object, so its events never reach the view.
///
/// One owner: `owner` is the tracker whose hand shows. Another tracker that sets its hand takes
/// it, so an exit that AppKit delivers after the next enter leaves the next view's hand alone. A
/// tracker clears the hand (the arrow) only while it is the owner, and only while the pointer is
/// still over its view in the top window, so an exit a menu's tracking loop swallowed never puts
/// the arrow over the page's own hand later.
///
/// A still pointer: the key child window resets the cursor in its display cycle (a page reload),
/// with no event for the tracker. `keepHand()`, called by the main run loop's cursor keeper
/// (`ArrowCursorView`) after each pass and after each pointer move, sets the owner's hand again.
@MainActor
public final class ClickableCursorTracker: NSResponder {
    /// The tracker whose hand shows now; nil when none does.
    private(set) static weak var owner: ClickableCursorTracker?

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
        inside = false
        release()
    }

    /// The view was enabled or disabled: under a still pointer the cursor follows at once.
    public func clickableStateDidChange() {
        guard inside else { return }
        update()
    }

    /// The view hides or changes window under a still pointer, with no exit event.
    public func viewWillLeave() {
        inside = false
        release()
    }

    /// After a run loop pass or a pointer move: the owner's hand again when the key child window
    /// reset the cursor under a still pointer. One read while no tracker shows its hand, and one
    /// cursor comparison while the hand still shows; it reads the pointer only when another cursor
    /// shows, and gives up the hand (setting nothing) once the pointer is no longer over its view.
    public static func keepHand() {
        guard let owner else { return }
        guard owner.currentCursor() !== NSCursor.pointingHand else { return }
        guard owner.inside, owner.handAllowed(), owner.pointerOverView(visibleOnly: true) else {
            Self.owner = nil
            return
        }
        owner.setCursor(.pointingHand)
    }

    private func update() {
        let over = pointerOverView(visibleOnly: true)
        if !over { inside = false }
        guard over, handAllowed() else { return release() }
        Self.owner = self
        setCursor(.pointingHand)
    }

    /// The hand goes only while this tracker owns it, and the arrow replaces it only while the
    /// pointer is still over this view's frame in the top window (not over the page, where the
    /// page set its own cursor) and another window has the key (the key window's rects decide).
    private func release() {
        guard showsHand else { return }
        Self.owner = nil
        guard let window = view?.window, !isKey(window), currentCursor() === NSCursor.pointingHand,
              pointerOverView(visibleOnly: false) else { return }
        setCursor(.arrow)
    }

    private func handAllowed() -> Bool {
        guard let view, let window = view.window, !isKey(window), !Self.hasHost(view) else { return false }
        return isClickable() && !view.isHiddenOrHasHiddenAncestor
    }

    /// The pointer is over the view (its visible rect, or its bounds for a view that just hid) in
    /// the top window under the pointer.
    private func pointerOverView(visibleOnly: Bool) -> Bool {
        guard let view, let window = view.window,
              let point = ClickableButton.pointer(in: window, screenPoint: mouseLocation(), topWindowNumber: topWindowNumber) else {
            return false
        }
        return (visibleOnly ? view.visibleRect : view.bounds).contains(view.convert(point, from: nil))
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
