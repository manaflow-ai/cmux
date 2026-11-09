public import AppKit
public import CmuxNextDesign

/// The floating Chief's own window, a launcher in the Raycast manner (user 2026-11-09: "it should be raycast-type
/// floating window"): borderless and rounded with a shadow, over every app and Space, never activating cmux. It opens
/// at once (no motion: it opens many times a day), centered high on the screen under the pointer, or where it was
/// left on that screen. A press on any empty space drags it, as on a title bar, and Cmd-drag moves it from anywhere;
/// Esc, Cmd-W or a click outside (it gives up the keys) dismisses it.
///
/// ```swift
/// let launcher = ChiefLauncherPanel(frames: FloatingChatFrames(defaults: .standard, storageKey: ChiefLauncherPanel.framesKey))
/// launcher.onDismiss = { hideTheChief() }
/// launcher.present(chiefPanelView)
/// launcher.takeKeys()
/// ```
@MainActor
public final class ChiefLauncherPanel: NSPanel, NSWindowDelegate {
    /// The defaults key of the saved frames, one per screen.
    public static let framesKey = "chiefLauncher.frames"
    /// How far the hand moves before a press on empty space drags the window: less is a click.
    static let dragThreshold: CGFloat = 3

    /// Esc, a click outside, Cmd-W: the owner hides the Chief (and calls ``dismiss()``).
    public var onDismiss: (@MainActor () -> Void)?
    /// The keys moved inside the window (the owner's panel grows or rests with them).
    public var onFirstResponderChange: (@MainActor () -> Void)?
    /// Where the window was left on each screen.
    public let frames: FloatingChatFrames

    private var drag: (start: NSPoint, origin: NSPoint, moved: Bool, swallowsPress: Bool)?
    private var dismissing = false

    /// - Parameter frames: Where the window was left on each screen; it saves there after each move and resize.
    public init(frames: FloatingChatFrames) {
        self.frames = frames
        super.init(contentRect: NSRect(origin: .zero, size: FloatingChatFrames.defaultSize),
                   styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView, .resizable], backing: .buffered, defer: true)
        ThemeScope.app.adopt(self)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isFloatingPanel = true
        level = .floating
        hidesOnDeactivate = false
        // Not hidden with cmux (Cmd-H): the global key shows it over another app without unhiding cmux.
        canHide = false
        becomesKeyOnlyIfNeeded = false
        isReleasedWhenClosed = false
        // A launcher opens many times a day: no opening motion.
        animationBehavior = .none
        minSize = FloatingChatFrames.minimumSize
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        setAccessibilityIdentifier("cmux.chiefLauncher")
        contentView = NSView(frame: NSRect(origin: .zero, size: FloatingChatFrames.defaultSize))
        delegate = self
    }

    override public var canBecomeKey: Bool { true }
    override public var canBecomeMain: Bool { false }

    /// Shows `content` filling the window; a hidden window first goes where it was left on the screen under the
    /// pointer (``placement(saved:in:)``). Never takes the keys (``takeKeys()`` does).
    public func present(_ content: NSView) {
        guard let host = contentView else { return }
        if content.superview !== host {
            content.removeFromSuperview()
            content.frame = host.bounds
            content.autoresizingMask = [.width, .height]
            host.addSubview(content)
        }
        guard !isVisible else { return }
        if let screen = Self.screenUnderPointer() {
            let target = Self.placement(saved: frames.frame(onDisplay: FloatingChatFrames.display(screen)), in: screen.visibleFrame)
            if frame != target { setFrame(target, display: false) }
        }
        orderFrontRegardless()
    }

    /// Takes the keys without activating cmux (the person stays in their app).
    public func takeKeys() {
        guard isVisible, !isKeyWindow else { return }
        WindowActivation.show(self, .raise)
    }

    /// Orders the window out (the owner hid the Chief); no ``onDismiss``.
    public func dismiss() {
        drag = nil
        orderOut(nil)
    }

    /// Where the window opens on a screen whose visible frame is `visible`: `saved` kept inside it, else the
    /// default size centered, its top a sixth of the way down.
    public static func placement(saved: CGRect?, in visible: CGRect) -> CGRect {
        let top = visible.maxY - (visible.height / 6).rounded()
        return FloatingChatFrames.placement(saved: saved, near: CGRect(x: visible.midX, y: top, width: 0, height: 0), in: visible)
    }

    static func screenUnderPointer() -> NSScreen? {
        let point = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) } ?? NSScreen.main
    }

    // MARK: Dismissal

    private func requestDismiss() {
        guard !dismissing, isVisible else { return }
        dismissing = true
        defer { dismissing = false }
        if let onDismiss { onDismiss() } else { dismiss() }
    }

    /// A click outside: the window gave up the keys to another app or window. A sheet or child window of its own
    /// (a menu, a popover) taking them is not outside.
    override public func resignKey() {
        super.resignKey()
        guard attachedSheet == nil, !(childWindows ?? []).contains(where: { $0.isVisible && $0.isKeyWindow }) else { return }
        requestDismiss()
    }

    override public func cancelOperation(_ sender: Any?) { requestDismiss() }

    /// Cmd-W dismisses the window; every other key goes on as usual (Cmd-I reaches the menu and hides it).
    override public func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .numericPad, .function])
        if event.type == .keyDown, flags == .command, event.charactersIgnoringModifiers?.lowercased() == "w" {
            requestDismiss()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override public func makeFirstResponder(_ responder: NSResponder?) -> Bool {
        let made = super.makeFirstResponder(responder)
        onFirstResponderChange?()
        return made
    }

    public func windowDidEndLiveResize(_ notification: Notification) { saveFrame() }

    private func saveFrame() {
        guard let screen else { return }
        frames.save(frame, onDisplay: FloatingChatFrames.display(screen))
    }

    // MARK: Dragging

    /// A press on empty space (a view that lets the window move under it, and no text, control, scroller or web
    /// page) drags the window once the hand moves; the view still gets the press, so a click stays a click. Cmd-drag
    /// moves it from anywhere and the view never sees that press.
    override public func sendEvent(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown:
            drag = nil
            let point = convertPoint(toScreen: event.locationInWindow)
            if Self.flags(event) == .command {
                drag = (point, frame.origin, false, true)
                return
            }
            if let content = contentView, let hit = content.hitTest(content.superview?.convert(event.locationInWindow, from: nil) ?? event.locationInWindow),
               Self.movesWindow(hit) {
                drag = (point, frame.origin, false, false)
            }
        case .leftMouseDragged:
            if var drag {
                let point = convertPoint(toScreen: event.locationInWindow)
                let dx = point.x - drag.start.x, dy = point.y - drag.start.y
                if drag.moved || hypot(dx, dy) >= Self.dragThreshold {
                    drag.moved = true
                    self.drag = drag
                    setFrameOrigin(NSPoint(x: (drag.origin.x + dx).rounded(), y: (drag.origin.y + dy).rounded()))
                    return
                }
                if drag.swallowsPress { return }
            }
        case .leftMouseUp:
            if let drag {
                self.drag = nil
                if drag.moved { saveFrame() }
                if drag.moved || drag.swallowsPress { return }
            }
        default: break
        }
        super.sendEvent(event)
    }

    private static func flags(_ event: NSEvent) -> NSEvent.ModifierFlags {
        event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .numericPad, .function])
    }

    /// Whether a press on `hit` may drag the window: it lets the window move under it (a label always does), and
    /// neither it nor a view above it is text, a control, a scroller or a web page, whose drags are their own.
    static func movesWindow(_ hit: NSView) -> Bool {
        var view: NSView? = hit
        while let next = view {
            if !isLabel(next), next is NSText || next is NSControl || next is NSScroller || NSStringFromClass(type(of: next)).hasPrefix("WK") {
                return false
            }
            view = next.superview
        }
        return isLabel(hit) || hit.mouseDownCanMoveWindow
    }

    private static func isLabel(_ view: NSView) -> Bool {
        guard let field = view as? NSTextField else { return false }
        return !field.isEditable && !field.isSelectable
    }
}
