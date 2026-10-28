// cmux: the compose bar's own controls as layers in one view. Not a vendored file.
import AppKit

/// The compose bar's own controls in one NSView: the send button (`ComposeSendButton`), the voice
/// controls (`ComposeVoiceControls`: mic, finish and the live waveform) and "Listening…"
/// (`ComposeListeningLine`) are CALayers of this view, not NSViews of their own.
///
/// Chromium's model: one NSView hosts a widget's whole views::View tree
/// (components/remote_cocoa/app_shim/bridged_content_view.mm), each control paints into layers, and
/// each control is an accessibility element that is no NSView
/// (ui/accessibility/platform/ax_platform_node_cocoa.mm). So this view hit-tests its controls, gives
/// each an accessibility element (`ComposeChromeElement`), and moves, shows or recolours a control by
/// changing its layers: AppKit has no layout pass, display or subview bookkeeping for them. A key in
/// the field touches none of them; they change only when the draft turns empty or not, the field
/// changes height, or a voice session starts or stops.
///
/// The view covers the pane and hosts its own layer tree, as `LayerHostView` does for
/// `HostView.composeHost` (a geometry-flipped root: the controls' frames are the pane's y-down
/// coordinates, the field's), so its frame changes only with the pane's size; outside a shown
/// control it takes no click (`hitTest`), so the text view and the transcript under it get theirs.
final class ComposeChromeView: NSView {
    let send = ComposeSendButton()
    let voice = ComposeVoiceControls()
    let listening = ComposeListeningLine()
    /// The hosted layer tree's root (AppKit never touches a hosted tree).
    private let root = CALayer()
    /// The Full Keyboard Access focus ring around the send button's disc (a hosted tree gets no
    /// AppKit focus ring).
    private let focusRing = CAShapeLayer()

    /// The control a press began on, and whether the pointer is still over it.
    private var pressed: Control?
    private var pressedInside = false
    /// The send button's hover area (only while it shows; covers only the button).
    private var hoverArea: NSTrackingArea?
    /// The shown controls' tool tip strings (their owners; AppKit does not keep them).
    private var toolTipLabels: [NSString] = []
    /// Whether Full Keyboard Access is on (the system setting; tests turn it on).
    var fullKeyboardAccess: @MainActor () -> Bool = { NSApp.isFullKeyboardAccessEnabled }
    /// How often the controls moved, showed or hid (tests: a plain key changes none of them).
    private(set) var controlsChanges = 0

    enum Control: Equatable { case send, mic, finish }

    override init(frame: NSRect) {
        super.init(frame: frame)
        root.isGeometryFlipped = true
        root.masksToBounds = false
        root.actions = ["bounds": NSNull(), "position": NSNull(), "sublayers": NSNull(), "contents": NSNull()]
        layer = root
        wantsLayer = true
        focusRing.actions = ["path": NSNull(), "hidden": NSNull(), "strokeColor": NSNull(), "contentsScale": NSNull()]
        focusRing.fillColor = nil
        focusRing.lineWidth = 3
        focusRing.isHidden = true
        for l in [listening.layer, send.layer, voice.layer, focusRing] { root.addSublayer(l) }
        send.owner = self
        voice.owner = self
        listening.owner = self
        rescale(DisplayScale.current)
    }
    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }

    // MARK: Controls

    /// The shown control at `p` (this view's coordinates); the voice controls are above the send
    /// button, as their views were.
    func control(at p: CGPoint) -> Control? {
        if !voice.isHidden {
            if voice.micFrame.contains(p) { return .mic }
            if voice.isListening, voice.finishFrame.contains(p) { return .finish }
        }
        if send.isShown, send.frame.contains(p) { return .send }
        return nil
    }

    /// The shown controls: their frames, tool tips and accessibility elements.
    private var shownControls: [ShownControl] {
        var shown: [ShownControl] = []
        if send.isShown { shown.append(ShownControl(frame: send.frame, label: CmuxStrings.send, element: send.element)) }
        if !voice.isHidden {
            if voice.isListening {
                shown.append(ShownControl(frame: voice.finishFrame, label: CmuxStrings.finishDictation, element: voice.finish.element))
            }
            shown.append(ShownControl(frame: voice.micFrame, label: voice.micLabel, element: voice.mic.element))
        }
        return shown
    }
    private struct ShownControl {
        let frame: CGRect
        let label: String
        let element: ComposeChromeElement
    }

    /// A control moved, showed or hid: the cursor, tool tip and hover rects follow (none of them is a
    /// layout or a display of this view), and VoiceOver hears a change of the controls shown.
    func controlsChanged(visibility: Bool) {
        controlsChanges += 1
        window?.invalidateCursorRects(for: self)
        removeAllToolTips()
        // AppKit shows a tool tip owner's description (here the control's label) and does not keep
        // the owner, so this view keeps the strings until the next change.
        let shown = shownControls
        toolTipLabels = shown.map { $0.label as NSString }
        for (c, label) in zip(shown, toolTipLabels) {
            // SAFETY: no user data (nil); the owner is kept in `toolTipLabels`.
            _ = unsafe addToolTip(c.frame, owner: label, userData: nil)
        }
        updateTrackingAreas()
        placeFocusRing()
        if visibility { NSAccessibility.post(element: self, notification: .layoutChanged) }
    }

    /// A colour for a layer, in this view's appearance (a dynamic colour resolves for it).
    func cgColor(_ color: NSColor) -> CGColor {
        var resolved = color.cgColor
        effectiveAppearance.performAsCurrentDrawingAppearance { resolved = color.cgColor }
        return resolved
    }

    /// The scale the layers' images and shapes draw at: the window's.
    private func rescale(_ s: CGFloat) {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for l in [root, focusRing] where l.contentsScale != s { l.contentsScale = s }
        send.rescale(s)
        voice.rescale(s)
        listening.rescale(s)
        CATransaction.commit()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let s = window?.backingScaleFactor { rescale(s) }
        controlsChanged(visibility: false)
    }
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        rescale(window?.backingScaleFactor ?? DisplayScale.current)
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        voice.appearanceChanged()
    }

    // MARK: Pointer

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden else { return nil }
        return control(at: convert(point, from: superview)) == nil ? nil : self
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() {
        for c in shownControls { addCursorRect(c.frame, cursor: .arrow) }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = hoverArea { removeTrackingArea(t); hoverArea = nil }
        guard send.isShown else { return }
        let t = NSTrackingArea(rect: send.frame, options: [.mouseEnteredAndExited, .activeInKeyWindow], owner: self)
        addTrackingArea(t)
        hoverArea = t
    }
    override func mouseEntered(with event: NSEvent) { send.setHovering(true) }
    override func mouseExited(with event: NSEvent) { send.setHovering(false) }

    private func point(_ e: NSEvent) -> CGPoint { convert(e.locationInWindow, from: nil) }
    private func rect(of c: Control) -> CGRect {
        switch c {
        case .send: return send.frame
        case .mic: return voice.micFrame
        case .finish: return voice.finishFrame
        }
    }
    private func setPressing(_ c: Control, _ on: Bool) {
        switch c {
        case .send: send.setPressing(on)
        case .mic: voice.mic.setPressing(on)
        case .finish: voice.finish.setPressing(on)
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard let c = control(at: point(event)) else { return }
        pressed = c
        pressedInside = true
        setPressing(c, true)
    }
    override func mouseDragged(with event: NSEvent) {
        guard let c = pressed else { return }
        let inside = rect(of: c).contains(point(event))
        guard inside != pressedInside else { return }
        pressedInside = inside
        setPressing(c, inside)
    }
    override func mouseUp(with event: NSEvent) {
        guard let c = pressed else { return }
        let inside = rect(of: c).contains(point(event))
        pressed = nil
        pressedInside = false
        setPressing(c, false)
        guard inside else { return }
        switch c {
        case .send: send.press()
        case .mic: voice.mic.onPress()
        case .finish: voice.finish.onPress()
        }
    }

    // MARK: Accessibility and keyboard

    /// The shown controls, each its own element (the view itself is no element).
    override func accessibilityChildren() -> [Any]? { shownControls.map { adopted($0.element) } }

    /// The element AppKit reports as focused while this view is the first responder: the send
    /// button's, not the view's unignored ancestor (Chromium: BridgedContentView's
    /// accessibilityFocusedUIElement, components/remote_cocoa/app_shim/bridged_content_view.mm).
    override var accessibilityFocusedUIElement: Any? {
        focusedElement.map { adopted($0) } ?? super.accessibilityFocusedUIElement
    }

    /// The control under a screen point (VoiceOver's mouse tracking, Voice Control, Accessibility
    /// Inspector), as BridgedContentView's accessibilityHitTest: hands the hit views::View's element.
    override func accessibilityHitTest(_ point: NSPoint) -> Any? {
        guard !isHidden, let window, let c = control(at: convert(window.convertPoint(fromScreen: point), from: nil)) else {
            return super.accessibilityHitTest(point)
        }
        return adopted(element(of: c))
    }

    /// The send button's element while this view has the keyboard focus; nil otherwise.
    var focusedElement: ComposeChromeElement? {
        window?.firstResponder === self && send.isShown ? send.element : nil
    }

    private func element(of c: Control) -> ComposeChromeElement {
        switch c {
        case .send: return send.element
        case .mic: return voice.mic.element
        case .finish: return voice.finish.element
        }
    }

    /// `e` with its parent the nearest element above this view (the view itself is ignored).
    private func adopted(_ e: ComposeChromeElement) -> ComposeChromeElement {
        e.setAccessibilityParent(NSAccessibility.unignoredAncestor(of: self))
        return e
    }

    /// Full Keyboard Access: Tab reaches the send button while it shows, Space or Return presses it;
    /// the focus ring is a ring layer around its disc.
    override var acceptsFirstResponder: Bool { send.isShown && fullKeyboardAccess() }
    override var canBecomeKeyView: Bool { acceptsFirstResponder }
    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        placeFocusRing(focused: ok)
        // The window makes this view its first responder after this returns; the clients read the
        // focused element after the notification.
        if ok, send.isShown { NSAccessibility.post(element: adopted(send.element), notification: .focusedUIElementChanged) }
        return ok
    }
    override func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        // Not the first responder from here on, whatever the window reports during the change.
        placeFocusRing(focused: false)
        return ok
    }
    /// The window became or resigned key (the pane's key-state observers, `ChatController.followKeyState`):
    /// the focus ring shows only in the key window.
    func windowKeyChanged(isKey: Bool) { placeFocusRing(windowIsKey: isKey) }
    /// Whether the Full Keyboard Access ring shows around the send button.
    var isFocusRingShown: Bool { !focusRing.isHidden }

    override func keyDown(with event: NSEvent) {
        if send.isShown, event.keyCode == 49 || event.keyCode == 36 || event.keyCode == 76 { send.press(); return }
        super.keyDown(with: event)
    }

    /// The ring shows around the disc while this view has the keyboard focus in the key window and
    /// the button shows (AppKit draws its focus ring only in the key window).
    private func placeFocusRing(focused: Bool? = nil, windowIsKey: Bool? = nil) {
        let key = windowIsKey ?? (window?.isKeyWindow == true)
        let on = key && (focused ?? (window?.firstResponder === self)) && send.isShown
        CATransaction.begin(); CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        if focusRing.isHidden == on { focusRing.isHidden = !on }
        guard on else { return }
        focusRing.strokeColor = cgColor(.keyboardFocusIndicatorColor)
        focusRing.path = CGPath.ellipse(in: send.discFrame.insetBy(dx: -2.5, dy: -2.5))
    }
}

/// One control of `ComposeChromeView` for VoiceOver and the accessibility API: a button with its
/// label, identifier and enabled state, its frame the control's, and a press that runs the control.
final class ComposeChromeElement: NSAccessibilityElement {
    /// The view the control is drawn in (its parent is that view's unignored ancestor, set by the view).
    weak var view: NSView?
    /// The control's frame in `view`'s coordinates.
    var frameInView: CGRect = .zero
    /// The press (VoiceOver, the accessibility API): true when it did something.
    var onPress: @MainActor () -> Bool = { false }

    override init() {
        super.init()
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }

    override func isAccessibilityElement() -> Bool { true }
    /// Focused while its view has the keyboard focus on it (Full Keyboard Access on the send button).
    override func isAccessibilityFocused() -> Bool {
        guard Thread.isMainThread else { return false }  // AppKit calls accessibility on main
        let view = self.view, me = ObjectIdentifier(self)
        return MainActor.assumeIsolated {  // main-proof: guarded by Thread.isMainThread above
            (view as? ComposeChromeView)?.focusedElement.map { ObjectIdentifier($0) } == me
        }
    }
    /// On screen, from the view's geometry at the time of the call.
    override func accessibilityFrame() -> NSRect {
        guard Thread.isMainThread else { return .zero }  // AppKit calls accessibility on main
        let view = self.view, frame = frameInView
        return MainActor.assumeIsolated {  // main-proof: guarded by Thread.isMainThread above
            guard let view, let window = view.window else { return .zero }
            return window.convertToScreen(view.convert(frame, to: nil))
        }
    }
    override func accessibilityPerformPress() -> Bool {
        guard Thread.isMainThread else { return false }  // AppKit calls accessibility on main
        let press = onPress
        return MainActor.assumeIsolated { press() }  // main-proof: guarded by Thread.isMainThread above
    }
}
