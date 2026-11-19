import AppKit
import CmuxNextDesign

/// The one "+ New workspace" row at the top of the workspace list while the sidebar row restyle is on
/// (`experiments.sidebarRowStyle`, ``SidebarRowStyle``; taste build 7, 2026-11-19: "One '+ New workspace' row at
/// top"). It stands in for the titlebar's + and its chooser, which hide meanwhile, so the sidebar has one New
/// Workspace control: a press runs the +'s action (`SidebarAction.newWorkspace(machine: nil, group: nil)`) and a
/// right-click opens the +'s menu (the chooser). Group headers keep their own +.
///
/// The sidebar places it between the band above and the list's scroll view (`SidebarView.layoutNewWorkspaceRow`):
/// one list row's height and band, at the list's inset, the list starting one row step lower. It is not a list row:
/// the list's layout, keys, drag and pool know nothing of it, so it costs the same at any list size.
///
/// Keyboard: Up from the list's first stop focuses it and Down from it enters the list (`SidebarArrowWalk`); Full
/// Keyboard Access reaches it with Tab; Space or Return press it. VoiceOver reads it as a button.
final class SidebarNewWorkspaceRowView: NSView {
    /// Runs the +'s action (the sidebar sets it).
    var onPress: (() -> Void)?
    /// The +'s right-click menu: the New Workspace chooser (the sidebar sets it).
    var menuProvider: (() -> NSMenu?)?

    private let label = SidebarRowView.label(font: SidebarStyle.titleFont)
    /// Hosts the leading + (the window's standard + look, glyph only: the row paints the band).
    private let glyph = NSView()
    private lazy var plus = PlusButtonLook(host: glyph)
    private lazy var keyRepaint = KeyWindowRepaint(self)

    /// The pointer is over the row (its own tracking area; a gallery sets it).
    var isHovered = false { didSet { if isHovered != oldValue { stateChanged(fades: true) } } }
    private(set) var isPressed = false { didSet { if isPressed != oldValue { stateChanged(fades: false) } } }
    private var isKeyFocused = false { didSet { if isKeyFocused != oldValue { needsDisplay = true } } }
    /// The next fill change came from hover: it fades on the rows' hover-out token, as a list row's does.
    private var fadesNextFill = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        focusRingType = .none
        layer?.cornerCurve = Metrics.tabCornerCurve
        glyph.wantsLayer = true
        glyph.setAccessibilityElement(false)
        plus.hoverStyle = .glyph
        plus.motion = Motion.feedback
        label.setAccessibilityElement(false)
        addSubview(glyph)
        addSubview(label)
        label.setString(Strings.newWorkspaceRow)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(Strings.newWorkspaceRow)
        setAccessibilityIdentifier("cmux.sidebar.newWorkspace.row")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    nonisolated override var isFlipped: Bool { true }
    nonisolated override var wantsUpdateLayer: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: Layout and paint

    override func layout() {
        super.layout()
        // Read on every layout, as the list rows do, so a density or text size change applies live.
        let b = bounds
        layer?.cornerRadius = SidebarStyle.rowCornerRadius
        let columns = SidebarStyle.columns(rowWidth: b.width)
        // The + starts its ink on the icon column's leading edge, where a workspace icon's ink starts (`iconColumnGlyphX`).
        let box = columns.iconBox, extent = Metrics.addGlyphExtent
        let ink = CGRect(x: (box - extent) / 2, y: (box - extent) / 2, width: extent, height: extent)
        let scale = max(window?.backingScaleFactor ?? 2, 1)
        let glyphX = (SidebarStyle.iconColumnGlyphX(leading: columns.lead, ink: ink) * scale).rounded() / scale
        glyph.frame = NSRect(x: glyphX, y: ((b.height - box) / 2 * scale).rounded() / scale, width: box, height: box)
        plus.layout(in: glyph.bounds, scale: scale)
        label.setFont(SidebarStyle.titleFont)
        let x = columns.text(hasLeadingMark: true) - SidebarStyle.labelCellPadding
        let h = ceil(label.intrinsicContentSize.height)
        label.frame = NSRect(x: x, y: SidebarStyle.textY(label, centerY: b.midY), width: max(0, b.width - x - Metrics.space2), height: h)
    }

    override func updateLayer() {
        performWithTheme {
            // A held row changes only its fill (design/pressed-state.md): the label and the + keep the hover ink.
            let fill: NSColor? = isPressed ? Palette.pressedFill : isHovered ? Palette.hoverFill : nil
            if let layer { ChromeHover.paint(layer, fill, animated: fadesNextFill, clearing: .hoverOut) }
            fadesNextFill = false
            label.setColor(isHovered ? Palette.textPrimary : Palette.textSecondary)
            layer?.borderColor = Palette.focusRing.cgColor
            layer?.borderWidth = KeyWindowRepaint.showsFocus(self, focused: isKeyFocused) ? Metrics.lineWidth(1.5) : 0
        }
        // The glyph look draws no fill, so its ink changes at once; an unchanged state repaints in the theme now.
        let state = PlusButtonLook.State(hovering: isHovered)
        if plus.state != state { plus.apply(state, animated: false) } else { plus.refresh() }
    }

    private func stateChanged(fades: Bool) {
        fadesNextFill = fades && !isHovered
        needsDisplay = true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        keyRepaint.track()
        needsLayout = true
    }

    override func viewDidHide() {
        super.viewDidHide()
        isHovered = false
        isPressed = false
        // focus-route: a hidden row gives back the keyboard it holds (the restyle turned off); it moves no one's focus elsewhere.
        if window?.firstResponder === self { window?.makeFirstResponder(nil) }
    }

    // MARK: Pointer

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas where area.owner === self { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }
    override func mouseDown(with event: NSEvent) { isPressed = true }

    /// Acts on release inside, as a button does.
    override func mouseUp(with event: NSEvent) {
        guard isPressed else { return }
        isPressed = false
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        onPress?()
    }

    /// The +'s right-click menu (the chooser), which the hidden titlebar + offered.
    override func menu(for event: NSEvent) -> NSMenu? { menuProvider?() }

    // MARK: Keyboard and accessibility

    override func accessibilityPerformPress() -> Bool {
        onPress?()
        return true
    }

    /// Focusable from the keyboard (the arrow walk, Tab with Full Keyboard Access), never by a click: a click runs the
    /// action and leaves focus where it was.
    override var acceptsFirstResponder: Bool {
        let mouse: Set<NSEvent.EventType> = [.leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp]
        return !(NSApp.currentEvent.map { mouse.contains($0.type) } ?? false)
    }

    override var canBecomeKeyView: Bool { NSApp.isFullKeyboardAccessEnabled && acceptsFirstResponder && !isHiddenOrHasHiddenAncestor }

    override func becomeFirstResponder() -> Bool {
        isKeyFocused = true
        return true
    }

    override func resignFirstResponder() -> Bool {
        isKeyFocused = false
        return true
    }

    override func keyDown(with event: NSEvent) {
        if SidebarUpdateToggle.isActivationKey(event) { onPress?(); return }
        // Up and Down walk the sidebar's rows, this one among them (`SidebarArrowWalk`).
        if SidebarArrowWalk.step(from: self, event) { return }
        super.keyDown(with: event)
    }
}
