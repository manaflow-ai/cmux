public import AppKit

/// The window of one floating pane: a child window of the app window that shows the pane's content.
///
/// It can be the key window and is never the main window, so the app window keeps its active look while a floating
/// pane has the keys. It is not a floating panel and it stays when the app is not active: it is content, at the
/// level of its parent. A person moves it by the bar at its top (``barHeight``) and changes its size by its edges.
/// It does not move by itself: only the bar, the size change and its owner set its frame. Each overlay of the app
/// window is above it (``UnderOverlayWindow``).
///
/// The keys in a panel are the keys of its parent's content: the parent's delegate hears that its window has the
/// keys when a panel gets them and that it lost them when a panel loses them, and a key equivalent typed in a panel
/// goes to the parent first.
public final class PanePanel: NSPanel, FocusRouting, UnderOverlayWindow {
    /// The style of each pane panel.
    public static let style: NSWindow.StyleMask = [.titled, .fullSizeContentView, .resizable]

    /// How far from the panel's edges the bar starts: the edge is the size change's.
    static let barInset: CGFloat = 5

    /// The id of the pane that the panel shows.
    public let pane: String
    public var routeInFlight: FocusRoute?
    /// The height of the bar at the panel's top that moves the panel.
    public var barHeight: CGFloat = 0
    /// A press of a pointer button in the panel, before the panel's views get it.
    public var onPress: (() -> Void)?
    /// A move by the bar ended: the panel is where the person left it.
    public var onMoved: (() -> Void)?

    /// Where a move by the bar started: the pointer on the display, and the panel's origin.
    private var move: (pointer: NSPoint, origin: NSPoint)?

    /// Whether a move by the bar is in progress.
    public var isMoving: Bool { move != nil }

    public init(pane: String, frame: NSRect) {
        self.pane = pane
        super.init(contentRect: frame, styleMask: Self.style, backing: .buffered, defer: true)
        isReleasedWhenClosed = false
        isFloatingPanel = false
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = false
        level = .normal
        collectionBehavior = [.fullScreenAuxiliary, .ignoresCycle]
        isMovable = false
        isMovableByWindowBackground = false
        animationBehavior = .none
        if styleMask.contains(.titled) {
            titleVisibility = .hidden
            titlebarAppearsTransparent = true
            for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] { standardWindowButton(button)?.isHidden = true }
        } else {
            hasShadow = true
        }
    }

    override public var canBecomeKey: Bool { true }
    override public var canBecomeMain: Bool { false }

    /// The owner gives the frame: AppKit does not move a panel back onto a display.
    override public func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }

    override public func becomeKey() {
        super.becomeKey()
        guard let parent else { return }
        parent.delegate?.windowDidBecomeKey?(Notification(name: NSWindow.didBecomeKeyNotification, object: parent))
    }

    override public func resignKey() {
        super.resignKey()
        guard let parent else { return }
        parent.delegate?.windowDidResignKey?(Notification(name: NSWindow.didResignKeyNotification, object: parent))
    }

    /// The key equivalents of the parent first, as when the parent has the keys; then the panel's own views.
    override public func performKeyEquivalent(with event: NSEvent) -> Bool {
        if parent?.performKeyEquivalent(with: event) == true { return true }
        return super.performKeyEquivalent(with: event)
    }

    /// Gives the keys to the window of `pane` in the family of `window` (an app window and its pane panels): the
    /// panel that shows `pane`, else `window`. Only while a window of that family has the keys: no other window
    /// and no other app loses them. Not in a press of a pointer button: the press chose the window that has the
    /// keys, and the pane under it gets the focus by the press itself.
    public static func moveKeys(in window: NSWindow?, toPane pane: String?) {
        let inPress = isPress(NSApp?.currentEvent?.type)
        guard let home = keyHome(in: window, toPane: pane, key: NSApp?.keyWindow, inPress: inPress) else { return }
        FocusRoute(.system, "the window of the pane that has the focus").makeKey(home)
    }

    /// Whether an event of `type` is a press of a pointer button.
    static func isPress(_ type: NSEvent.EventType?) -> Bool {
        type == .leftMouseDown || type == .rightMouseDown || type == .otherMouseDown
    }

    /// The window that ``moveKeys(in:toPane:)`` gives the keys to, with `key` the window that has them now; nil
    /// when the keys stay where they are.
    static func keyHome(in window: NSWindow?, toPane pane: String?, key: NSWindow?, inPress: Bool) -> NSWindow? {
        guard !inPress, let window, let key else { return nil }
        let panels = (window.childWindows ?? []).compactMap { $0 as? PanePanel }
        guard key === window || panels.contains(where: { $0 === key }) else { return nil }
        let home: NSWindow = pane.flatMap { pane in panels.first { $0.pane == pane } } ?? window
        return home === key ? nil : home
    }

    /// Whether `point` (window coordinates) is in the bar.
    public func isInBar(_ point: NSPoint) -> Bool {
        let size = frame.size
        return barHeight > 0 && point.y >= size.height - barHeight && point.y <= size.height - Self.barInset
            && point.x >= Self.barInset && point.x <= size.width - Self.barInset
    }

    /// The frame origin of a move by the bar that started with the pointer at `start` and the panel at `origin`, with
    /// the pointer now at `pointer` (display coordinates): the panel follows the pointer, with no other rule.
    public nonisolated static func origin(movedFrom origin: NSPoint, pointerFrom start: NSPoint, to pointer: NSPoint) -> NSPoint {
        NSPoint(x: origin.x + pointer.x - start.x, y: origin.y + pointer.y - start.y)
    }

    override public func sendEvent(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown:
            onPress?()
            guard isInBar(event.locationInWindow) else { break }
            move = (NSEvent.mouseLocation, frame.origin)
            if !isKeyWindow { FocusRoute(.person, "a press on a floating pane's bar").makeKey(self) }
            return
        case .rightMouseDown, .otherMouseDown:
            onPress?()
        case .leftMouseDragged:
            guard let move else { break }
            setFrameOrigin(Self.origin(movedFrom: move.origin, pointerFrom: move.pointer, to: NSEvent.mouseLocation))
            return
        case .leftMouseUp:
            guard move != nil else { break }
            move = nil
            onMoved?()
            return
        default:
            break
        }
        super.sendEvent(event)
    }
}
