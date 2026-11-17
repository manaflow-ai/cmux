public import AppKit

/// The window of a cmux dialog that floats over every app: a prompt the person at this Mac answers wherever they
/// are (a device asking to see or control this Mac, the join consent, "Computer use can act as me"). It draws the
/// one cmux dialog card (``CmuxDialogView``: the dialog glass, concentric corners, keycap buttons) in a borderless,
/// non-activating panel at the top right of the main screen, on every Space and over full-screen apps.
///
/// Showing it never takes the keyboard or the frontmost app: a Return typed into another app as it appears answers
/// nothing. A click into the card makes it key without activating cmux, so its keys (Return, Escape, Tab) work from
/// then on, as its keycaps say.
///
/// The card keeps the glass's key look while the panel is not key (the app's ``ActiveLookScope``): an inactive
/// window's glass turns a flat grey. Liquid Glass on macOS 26, the blur before it, the opaque surface under Reduce
/// Transparency (``CmuxDialogCardSurface``).
@MainActor
// glass-opaque-allow: never opaque: the panel only hosts CmuxDialogView, whose CmuxDialogCardSurface builds the dialog glass
open class CmuxFloatingDialogPanel: NSPanel {
    /// How far the card sits from the screen's visible top and trailing edges.
    public static var screenMargin: CGFloat { Metrics.space5 }

    /// The card shown now; nil while none is.
    public private(set) var dialogView: CmuxDialogView?

    /// A panel with `identifier` (accessibility, automation).
    public init(identifier: String) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 380, height: 160),
                   styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView], backing: .buffered, defer: true)
        ThemeScope.app.adopt(self)
        isOpaque = false
        backgroundColor = .clear
        // The card casts its own shadow, shaped to its corners (``CmuxDialogCardSurface``).
        hasShadow = false
        isFloatingPanel = true
        level = .statusBar
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        isReleasedWhenClosed = false
        animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        setAccessibilityIdentifier(identifier)
        let root = FloatingDialogRoot()
        root.wantsLayer = true
        contentView = root
    }

    open override var canBecomeKey: Bool { true }
    open override var canBecomeMain: Bool { false }

    /// The app's one active-look scope, from any of its windows (nil in tests with no app window).
    static var appActiveLook: ActiveLookScope? {
        NSApp.windows.lazy.compactMap(\.backdropActiveLook).first
    }

    /// Shows `spec` in the card (replacing the one shown), sized to it at the top right of the main screen, and
    /// orders the panel in over every app without activating cmux. `onPress` gets each press by click or key; a
    /// ``CmuxDialogButton/personOnly`` button's press is its host's to ignore.
    @discardableResult
    public func show(_ spec: CmuxDialogSpec, onPress: @escaping (String) -> Void) -> CmuxDialogView {
        let wasVisible = isVisible
        let hadKeyboard = dialogView?.containsKeyboard == true
        let dialog = CmuxDialogPresentation.standalone(spec, activeLook: Self.appActiveLook, onPress: onPress)
        let view = CmuxDialogView(dialog: dialog)
        dialogView?.removeFromSuperview()
        dialogView = view
        let root = contentView ?? NSView()
        view.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: Self.shadowRoom),
            view.topAnchor.constraint(equalTo: root.topAnchor, constant: Self.shadowRoom),
        ])
        root.layoutSubtreeIfNeeded()
        place(view.fittingSize)
        if hadKeyboard { FocusRoute(.system, "a floating dialog redrew its card: keep its keys").moveKeyboard(in: self, to: view) }
        orderFrontRegardless()
        if !wasVisible { enter() }
        return view
    }

    /// Takes the card away at once, with no fade: an answered prompt never lingers to take a second click.
    public func hide() {
        orderOut(nil)
        dialogView?.removeFromSuperview()
        dialogView = nil
    }

    /// The window is this much larger than the card on every side, so the card's shadow is not clipped.
    static var shadowRoom: CGFloat { PopupStyle.standard.shadowMargin }

    /// Sizes the panel to a card `size` big, the card ``screenMargin`` in from the main screen's visible top right.
    private func place(_ size: NSSize) {
        let room = Self.shadowRoom
        let area = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? NSRect(origin: .zero, size: size)
        let card = NSRect(x: area.maxX - size.width - Self.screenMargin, y: area.maxY - size.height - Self.screenMargin,
                          width: size.width, height: size.height)
        setFrame(card.insetBy(dx: -room, dy: -room), display: true)
    }

    /// The card's frame on screen while it shows (tests, placement).
    public var cardFrame: CGRect? {
        guard isVisible, dialogView != nil else { return nil }
        return frame.insetBy(dx: Self.shadowRoom, dy: Self.shadowRoom)
    }

    /// Fades the card in and grows it a little from its top trailing corner, as an overlay card opens (Reduce
    /// Motion and animations off: at once).
    private func enter() {
        guard let layer = contentView?.layer, let content = contentView, Motion.canAnimate(in: content) else { return }
        Motion.overlays.set(layer, "opacity", to: Float(1), fade: .fadeIn, from: Float(0))
        guard Motion.overlays.animatesMovement(in: self) else { return }
        let pivot = CGPoint(x: layer.bounds.maxX - Self.shadowRoom, y: layer.bounds.maxY - Self.shadowRoom)
        Motion.overlays.set(layer, "sublayerTransform", to: NSValue(caTransform3D: CATransform3DIdentity), spring: .appear,
                            from: NSValue(caTransform3D: Motion.scale(Motion.panelOpenScale, about: pivot, in: layer)))
    }

    /// A click into the card gives it the keyboard (Return, Escape, Tab), without activating cmux.
    open override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown, let view = dialogView, !view.containsKeyboard {
            let route = FocusRoute(.person, "a click into a floating dialog's card gives it the keyboard")
            route.makeKey(self)
            route.moveKeyboard(in: self, to: view)
        }
        super.sendEvent(event)
    }
}

/// The panel's clear root: it lays the card at its top left, a shadow's room in, and takes no clicks itself (the
/// shadow band lets them through to the app under it).
@MainActor
private final class FloatingDialogRoot: NSView {
    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }
}
