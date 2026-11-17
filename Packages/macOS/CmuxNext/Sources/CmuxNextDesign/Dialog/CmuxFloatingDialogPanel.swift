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

    /// The view shown now (the card, or a host's view that holds one); nil while none is.
    public private(set) var hosted: NSView?

    /// The card shown now; nil while none is.
    public var dialogView: CmuxDialogView? {
        guard let hosted else { return nil }
        return hosted as? CmuxDialogView ?? Self.firstCard(under: hosted)
    }

    private static func firstCard(under view: NSView) -> CmuxDialogView? {
        for sub in view.subviews {
            if let card = sub as? CmuxDialogView ?? firstCard(under: sub) { return card }
        }
        return nil
    }

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
    public static var appActiveLook: ActiveLookScope? {
        NSApp.windows.lazy.compactMap(\.backdropActiveLook).first
    }

    /// Shows `spec` in the card (replacing the one shown), sized to it at the top right of the main screen, and
    /// orders the panel in over every app without activating cmux. `onPress` gets each press by click or key; a
    /// ``CmuxDialogButton/personOnly`` button's press is its host's to ignore.
    @discardableResult
    public func show(_ spec: CmuxDialogSpec, onPress: @escaping (String) -> Void) -> CmuxDialogView {
        let view = CmuxDialogView(dialog: .standalone(spec, activeLook: Self.appActiveLook, onPress: onPress))
        present(view)
        return view
    }

    /// Shows `content`, a view that holds one cmux dialog card (a consent's own view around its card), as ``show(_:onPress:)``
    /// shows a spec. Showing the view already shown again re-sizes and re-places the panel to it.
    public func present(_ content: NSView) {
        let wasVisible = isVisible
        let hadKeyboard = dialogView?.containsKeyboard == true
        if hosted !== content {
            hosted?.removeFromSuperview()
            hosted = content
            let root = contentView ?? NSView()
            content.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(content)
            NSLayoutConstraint.activate([
                content.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: Self.shadowRoom),
                content.topAnchor.constraint(equalTo: root.topAnchor, constant: Self.shadowRoom),
            ])
        }
        contentView?.layoutSubtreeIfNeeded()
        place(content.fittingSize)
        if hadKeyboard, let card = dialogView {
            FocusRoute(.system, "a floating dialog redrew its card: keep its keys").moveKeyboard(in: self, to: card)
        }
        orderFrontRegardless()
        if !wasVisible { enter() }
    }

    /// Takes the card away at once, with no fade: an answered prompt never lingers to take a second click.
    public func hide() {
        orderOut(nil)
        hosted?.removeFromSuperview()
        hosted = nil
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
        guard isVisible, hosted != nil else { return nil }
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

/// A view that holds one cmux dialog card and draws it again from a new spec (a consent whose state changed: a write
/// in flight, an error): the floating consents' content (``CmuxFloatingDialogPanel/present(_:)``). It is the card's
/// size; the card brings the glass, the corners, the buttons and their keys.
@MainActor
open class CmuxDialogHostView: NSView {
    /// The card drawn now.
    public private(set) var card: CmuxDialogView?

    public override init(frame: NSRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") } // crash-allow: never decoded from a nib

    /// Draws `spec` in a new card, in place of the one drawn; `onPress` gets each press by click or key.
    @discardableResult
    public func draw(_ spec: CmuxDialogSpec, onPress: @escaping (String) -> Void) -> CmuxDialogView {
        let hadKeyboard = card?.containsKeyboard == true
        card?.removeFromSuperview()
        let view = CmuxDialogView(dialog: .standalone(spec, activeLook: CmuxFloatingDialogPanel.appActiveLook, onPress: onPress))
        addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: leadingAnchor),
            view.trailingAnchor.constraint(equalTo: trailingAnchor),
            view.topAnchor.constraint(equalTo: topAnchor),
            view.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        card = view
        layoutSubtreeIfNeeded()
        if hadKeyboard { FocusRoute(.system, "a dialog card redrew: keep its keys").moveKeyboard(in: window, to: view) }
        return view
    }

    open override var fittingSize: NSSize { card?.fittingSize ?? .zero }
}
