public import AppKit
import CmuxNextDesign

/// The Quick Agent Chat panel: a borderless composer floating over any app
/// and every Space. Unlike `ActiveAppKeyPanel` it takes the keys while cmux
/// is in the background, without activating cmux, so the summoning hot key
/// leaves the user in their app.
public final class QuickComposerPanel: NSPanel, QuickComposerWindow, NSWindowDelegate {
    static let size = CGSize(width: 680, height: 220)

    public var onResignKey: (() -> Void)?
    public var onCancel: (() -> Void)?
    private let surface = Glass.makeOverlayPanel(cornerRadius: Metrics.panelCornerRadius)
    /// The floating chat (cx-b9qi, `QuickComposerPanel+Floating`).
    var holdsChat = false
    /// Folded to its compact bar; `expandedHeight` is the height it opens back to.
    var isCollapsed = false
    var expandedHeight: CGFloat?
    let frames = FloatingChatFrames(defaults: .standard)
    let grip = FloatingChatGrip()

    public init() {
        super.init(
            contentRect: NSRect(origin: .zero, size: Self.size),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: true
        )
        ThemeScope.app.adopt(self)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isFloatingPanel = true
        level = .floating
        hidesOnDeactivate = false
        // Not hidden with cmux (⌘H, Hide Others): Start Agent from Any App orders it in without unhiding the app.
        canHide = false
        becomesKeyOnlyIfNeeded = false
        isMovableByWindowBackground = true
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        setAccessibilityIdentifier("cmux.quickComposer")
        surface.translatesAutoresizingMaskIntoConstraints = true
        surface.autoresizingMask = [.width, .height]
        surface.frame = NSRect(origin: .zero, size: Self.size)
        contentView = surface
        grip.frame = NSRect(x: 0, y: Self.size.height - FloatingChatGrip.height, width: Self.size.width, height: FloatingChatGrip.height)
        grip.autoresizingMask = [.width, .minYMargin]
        grip.isHidden = true
        surface.addSubview(grip)
        delegate = self
    }

    override public var canBecomeKey: Bool { true }
    override public var canBecomeMain: Bool { false }

    public func present(_ content: NSView, focus: NSView?) {
        // Read per show: the panel is reused, and motion settings change live.
        animationBehavior = Motion.overlays.animatesMovement ? .utilityWindow : .none
        if content.superview !== surface.contentView {
            surface.contentView.subviews.forEach { $0.removeFromSuperview() }
            content.frame = surface.contentView.bounds
            content.autoresizingMask = [.width, .height]
            // The page paints edge to edge; the corners clip it to the panel's shape.
            content.wantsLayer = true
            content.layer?.cornerRadius = Metrics.panelCornerRadius
            content.layer?.cornerCurve = .continuous
            content.layer?.masksToBounds = true
            surface.contentView.addSubview(content)
        }
        // The floating chat stays where it was moved to; summoned on another screen, it opens where it was left there.
        if !isVisible, let screen = Self.screenUnderPointer() {
            let composer = Self.placement(size: holdsChat ? Self.size : frame.size, in: screen.visibleFrame)
            let display = FloatingChatFrames.display(screen)
            if !holdsChat {
                setFrame(composer, display: false)
            } else if let target = FloatingChatFrames.summoned(onDisplay: self.screen.map(FloatingChatFrames.display), toDisplay: display,
                                                               saved: frames.frame(onDisplay: display), near: composer, in: screen.visibleFrame) {
                setFrame(target, display: false)
            }
        }
        // Raise never activates the app; under no-activate it does not take the keys either.
        WindowActivation.show(self, .raise)
        if let focus { makeFirstResponder(focus) }
    }

    public func dismiss() {
        orderOut(nil)
    }

    /// Horizontally centered, its top a quarter of the way down `visible`,
    /// kept inside it.
    static func placement(size: CGSize, in visible: CGRect) -> CGRect {
        let width = min(size.width, visible.width)
        let height = min(size.height, visible.height)
        let x = visible.midX - width / 2
        let top = visible.maxY - visible.height / 4
        let y = max(visible.minY, top - height)
        return CGRect(x: x.rounded(), y: y.rounded(), width: width, height: height)
    }

    static func screenUnderPointer() -> NSScreen? {
        let point = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) } ?? NSScreen.main
    }

    /// ⌘-drag anywhere moves the floating chat, as it moves any background
    /// window; the page never sees that press.
    override public func sendEvent(_ event: NSEvent) {
        if holdsChat, event.type == .leftMouseDown,
           event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .numericPad, .function]) == .command {
            performDrag(with: event)
            return
        }
        super.sendEvent(event)
    }

    override public func resignKey() {
        super.resignKey()
        onResignKey?()
    }

    override public func cancelOperation(_ sender: Any?) {
        onCancel?()
    }

    /// Cmd-W hides the panel. The page gets every key first; of the rest,
    /// editing keys (copy, paste, select all, undo, redo) go on to the Edit
    /// menu, and other command keys stop here, since the main menu would act
    /// on the window behind (Close Tab, New Tab, Quit).
    override public func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown else { return super.performKeyEquivalent(with: event) }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .numericPad, .function])
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        if flags == .command, key == "w" {
            onCancel?()
            return true
        }
        if super.performKeyEquivalent(with: event) { return true }
        let editing = (flags == .command && Self.editingKeys.contains(key)) || (flags == [.command, .shift] && key == "z")
        return flags.contains(.command) && !editing
    }

    private static let editingKeys: Set<String> = ["a", "c", "v", "x", "z"]
}
