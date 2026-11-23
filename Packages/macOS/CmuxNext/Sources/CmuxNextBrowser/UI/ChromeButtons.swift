import AppKit
import CmuxNextCompat
import CmuxNextWakeups
import CmuxNextDesign
import CmuxNextIcons

/// Borderless icon button with gray hover and press fills (no accent color).
final class ChromeIconButton: ClickableButton {
    private let density = DensityBinding()
    /// The pack icon the button draws (`BrowserToolbarReport.icons`).
    private(set) var iconName = IconName.placeholder
    private var iconLabel = ""
    /// Where the pointer is now (`OmnibarPointer`); a disabled button shows none.
    private var hover: PointerHover?
    var isHovering: Bool { hover?.isHovering ?? false }

    /// Toolbar buttons use the omnibar geometry (`OmnibarStyle`); others the
    /// compact overlay size.
    private let isToolbar: Bool
    /// False where the tooltip would only repeat the icon's name (Back, Forward,
    /// Reload/Stop, More: Lawrence 2026-10-13). The accessibility label stays.
    var showsToolTip: Bool {
        didSet { if showsToolTip != oldValue { themedToolTip = showsToolTip ? iconLabel : nil } }
    }
    /// A menu for right-click and long-press (Back / Forward entries).
    var menuProvider: (() -> NSMenu?)?
    var onPointerEnter: (() -> Void)?  // the pointer came onto it (the Extensions button's bubble is made then)
    private let holdTimer = DemandTimer(owner: "ChromeIconButton.hold")
    private var showedHoldMenu = false
    /// A press opens the button's menu at once instead of on the release (the toolbar's media,
    /// Downloads, profile, theme and More), as a pop-up button's `NSMenu` and Chrome's toolbar menus do,
    /// so press, drag onto a row and release picks it (Leo: "so he click and hold on the context menu
    /// start and then it goes over and then release should go"). A native menu tracks the held press
    /// itself; a glass one follows it through ``pressTracker``.
    var opensOnPress = false
    /// The glass menu this button's held press opened (``GlassMenu/trackPress(_:)``): the button keeps
    /// the mouse, so it hands the press's drags and its release on. Cleared at each press and release.
    var pressTracker: ((NSEvent) -> Void)?
    /// Whether a press that opened the menu (``opensOnPress``) is still held.
    private(set) var holdsPress = false

    init(icon: IconName, label: String, action: Selector?, target: AnyObject?, toolbar: Bool = false, toolTip: Bool = true) {
        isToolbar = toolbar
        showsToolTip = toolTip
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        isBordered = false
        bezelStyle = .regularSquare
        imagePosition = .imageOnly
        iconName = icon
        iconLabel = label
        self.action = action
        self.target = target
        themedToolTip = showsToolTip ? label : nil
        setAccessibilityLabel(label)
        wantsLayer = true
        NSLayoutConstraint.activate([
            density.bind(widthAnchor.constraint(equalToConstant: 0)) { [weak self] in self?.side(toolbar: toolbar) ?? 0 },
            density.bind(heightAnchor.constraint(equalToConstant: 0)) { [weak self] in self?.side(toolbar: toolbar) ?? 0 },
        ])
        density.update { [weak self] in
            guard let self else { return }
            // The tab's ratio on its own side (Lucas 2026-11-15: one shape at every density).
            layer?.cornerRadius = Metrics.buttonCornerRadius(proportionalTo: side(toolbar: toolbar))
            applyIcon()
        }
        density.start()
        hover = PointerHover(self) { [weak self] in self?.updateFill(animated: true); if $0 { self?.onPointerEnter?() } }
        hover?.isHoverable = { [weak self] in self?.isEnabled ?? false }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// The button's side: a toolbar button's on the window's pixels (square on a 1x display too), else the overlay's.
    private func side(toolbar: Bool) -> CGFloat {
        toolbar ? OmnibarStyle.buttonSize(scale: OmnibarStyle.scale(of: self)) : BrowserMetrics.controlHeight
    }

    /// A move to a screen with another scale snaps the side again.
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        density.reapply()
    }

    /// Unchanged icon and label keep the current image: a new NSImage
    /// makes AppKit lay out and redraw the button.
    func setIcon(_ icon: IconName, label: String) {
        guard icon != iconName || label != iconLabel || drawnGlyph == nil else { return }
        iconName = icon
        iconLabel = label
        applyIcon()
    }

    /// The icon's side instead of the toolbar's or the overlay's (More draws the app's ⋮ at
    /// `OverflowButton.glyphSize`); read on each density change.
    var iconSide: (() -> CGFloat)? { didSet { applyIcon() } }

    /// A toolbar button's glyph, its ink in the middle of the hover box on whole pixels (Lucas 2026-11-18: "the
    /// containers/hover is not centered within the icon"); the cell would center the glyph's image instead.
    private lazy var glyphView: InkCenteredGlyphView = {
        let view = InkCenteredGlyphView(frame: bounds)
        view.autoresizingMask = [.width, .height]
        addSubview(view)
        return view
    }()

    /// The glyph the button draws: the toolbar's in ``glyphView``, an overlay's as the cell's image.
    var drawnGlyph: NSImage? { isToolbar ? glyphView.glyph : image }
    /// The image the button shows, centered in its square: a toolbar button's is the box's size, its ink centered.
    var drawnImage: NSImage? { isToolbar ? glyphView.image : image }

    private func applyIcon() {
        let label = iconLabel
        let side = iconSide?() ?? (isToolbar ? OmnibarStyle.toolbarIconSize : CGFloat.iconRowSize(forLabelPointSize: BrowserMetrics.symbolPointSize))
        let icon = NSImage.icon(iconName, size: side)
        icon.accessibilityDescription = label
        if isToolbar {
            image = nil
            glyphView.glyph = icon
            glyphView.contentTintColor = contentTintColor
        } else {
            image = icon
        }
        themedToolTip = showsToolTip ? label : nil
        setAccessibilityLabel(label)
    }

    override var isEnabled: Bool {
        didSet {
            guard isEnabled != oldValue else { return }
            alphaValue = isEnabled ? 1 : 0.35
            hover?.refresh()
            updateFill()
        }
    }

    override var isHighlighted: Bool {
        didSet { updateFill() }
    }

    /// A toggle that is on (design mode, open DevTools) keeps the pressed
    /// fill; the app accent is a neutral gray, so a tint would not read.
    var isOn = false {
        didSet { if isOn != oldValue { updateFill() } }
    }

    /// A ring around the icon (`BrowserToolbarButtonState.progress`): 0...1
    /// fills that much of it from the top, clockwise; a negative value (size
    /// unknown) draws a short arc; nil hides it.
    var progress: Double? {
        didSet { if progress != oldValue { updateProgressRing() } }
    }
    private var ringTrack: CAShapeLayer?
    private var ringArc: CAShapeLayer?

    private func updateProgressRing() {
        guard let layer, let progress else {
            ringTrack?.isHidden = true
            ringArc?.isHidden = true
            return
        }
        let track = ringTrack ?? makeRingLayer(in: layer)
        let arc = ringArc ?? makeRingLayer(in: layer)
        ringTrack = track
        ringArc = arc
        // No implicit animation: the ring follows the bytes in steps (motion: allow, it never animates).
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let inset: CGFloat = 2.5
        let rect = bounds.insetBy(dx: inset, dy: inset)
        let path = CGMutablePath()
        // From 12 o'clock, clockwise on screen: in a flipped view y grows down,
        // so the top is -90° and a growing angle turns clockwise.
        let top: CGFloat = isFlipped ? -.pi / 2 : .pi / 2
        path.addArc(center: CGPoint(x: rect.midX, y: rect.midY), radius: min(rect.width, rect.height) / 2,
                    startAngle: top, endAngle: isFlipped ? top + 2 * .pi : top - 2 * .pi, clockwise: !isFlipped)
        for ring in [track, arc] {
            ring.frame = layer.bounds
            ring.path = path
            ring.isHidden = false
        }
        performWithTheme {
            track.strokeColor = Palette.textPrimary.withAlphaComponent(0.18).cgColor
            arc.strokeColor = Palette.textPrimary.cgColor
        }
        arc.strokeStart = 0
        arc.strokeEnd = progress < 0 ? 0.2 : CGFloat(max(0.02, min(1, progress)))
        CATransaction.commit()
    }

    private func makeRingLayer(in layer: CALayer) -> CAShapeLayer {
        let ring = CAShapeLayer()
        ring.fillColor = nil
        ring.lineWidth = 2
        ring.lineCap = .round
        ring.actions = ["strokeEnd": NSNull(), "path": NSNull(), "strokeColor": NSNull(), "hidden": NSNull()]
        layer.addSublayer(ring)
        return ring
    }

    override func layout() {
        super.layout()
        if isToolbar { glyphView.frame = bounds }
        if progress != nil { updateProgressRing() }
    }

    /// Chrome's pressed lock: the button keeps its pressed fill while its menu or bubble is
    /// open. When it closes the hover is read again from the pointer: an `NSMenu` tracks the
    /// mouse itself, so the button got no exit event while it was open (u2426).
    var isMenuOpen = false {
        didSet {
            guard isMenuOpen != oldValue else { return }
            if !isMenuOpen { hover?.refresh() }
            updateFill()
        }
    }

    // A button hidden under a still pointer (collapsed, its tab parked)
    // gets no exit event: hover follows the pointer and the frame instead.
    override func viewDidHide() {
        super.viewDidHide()
        hover?.refresh()
    }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        hover?.refresh()
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        NSMenu.withoutSystemItems(menuProvider?() ?? super.menu(for: event))
    }

    /// A right-click presses a button whose press opens a menu (the toolbar's
    /// profile, theme and More, cx-2lm4): right-click shows the same menu.
    var rightClickPresses = false

    override func rightMouseDown(with event: NSEvent) {
        guard rightClickPresses, isEnabled else { return super.rightMouseDown(with: event) }
        performClick(nil)
    }

    /// A press held for 0.4 s shows the menu under the button instead of
    /// clicking (long-press Back and Forward).
    override func mouseDown(with event: NSEvent) {
        showedHoldMenu = false
        pressTracker = nil
        holdsPress = false
        // Control-click stays a right-click (`menu(for:)`); every other press opens the menu now.
        if opensOnPress, isEnabled, !event.modifierFlags.contains(.control) {
            holdsPress = true
            _ = sendAction(action, to: target)
            return
        }
        if menuProvider != nil, isEnabled {
            holdTimer.schedule(after: .milliseconds(400)) { @MainActor [weak self] in self?.showHoldMenu() }
        }
        super.mouseDown(with: event)
        holdTimer.cancel()
    }

    /// The held press's drags go to the menu it opened (``pressTracker``).
    override func mouseDragged(with event: NSEvent) {
        guard holdsPress else { return super.mouseDragged(with: event) }
        pressTracker?(event)
    }

    /// The held press's release goes to the menu it opened: on a row it runs it, on the button it is a
    /// click and the menu stays open, anywhere else it closes the menu (``GlassMenu/trackPress(_:)``).
    override func mouseUp(with event: NSEvent) {
        guard holdsPress else { return super.mouseUp(with: event) }
        holdsPress = false
        let tracker = pressTracker
        pressTracker = nil
        tracker?(event)
    }

    override func sendAction(_ action: Selector?, to target: Any?) -> Bool {
        guard !showedHoldMenu else { return false }
        return super.sendAction(action, to: target)
    }

    private func showHoldMenu() {
        guard let menu = menuProvider?() else { return }
        showedHoldMenu = true
        // From a run-loop callout, not the timer's main-actor job: a menu tracking inside a main-queue
        // job holds the main queue until it closes, and the click that closes it waits on everything
        // queued meanwhile (Leo, 2026-10-29: "clicking out of a fucking context menu is sometimes slow").
        MainRunLoopBlock.perform { [weak self] in
            guard let self, window != nil else { return }
            isMenuOpen = true
            menu.popUp(positioning: nil, at: CmuxPopoverAnchor.menuPoint(for: menu, in: self, gap: 2), in: self)
            isMenuOpen = false
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateFill()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        hover?.refresh()
        updateFill()
    }

    private func updateFill(animated: Bool = false) {
        performWithTheme {
            let color: NSColor = if !isEnabled {
                .clear
            } else if isHighlighted || isOn || isMenuOpen {
                Palette.selectionFill
            } else if isHovering, DesignSettings.shared.showsHoverFills {
                Palette.hoverFill
            } else {
                .clear
            }
            // Hover eases in and clears at once; a press shows at once (ChromeHover.fade).
            if let layer { ChromeHover.paint(layer, color, animated: animated && window != nil, pressed: isHighlighted) }
            contentTintColor = isToolbar ? Palette.textPrimary : Palette.textSecondary
            if isToolbar { glyphView.contentTintColor = contentTintColor }
        }
        // The ring's colors follow the theme with the fill.
        if progress != nil { updateProgressRing() }
    }
}

/// Text button for prompts and error pages. `prominent` uses a stronger
/// gray fill instead of the system accent.
class ChromeTextButton: ClickableButton {
    private let density = DensityBinding()
    private let prominent: Bool
    private var hover: PointerHover?
    private var isHovering: Bool { hover?.isHovering ?? false }
    private var titleText = ""

    init(title: String, prominent: Bool, action: Selector?, target: AnyObject?) {
        self.prominent = prominent
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        isBordered = false
        bezelStyle = .regularSquare
        self.action = action
        self.target = target
        wantsLayer = true
        density.bind(heightAnchor.constraint(equalToConstant: 0)) { BrowserMetrics.controlHeight }.isActive = true
        titleText = title
        density.update { [weak self] in
            guard let self else { return }
            layer?.cornerRadius = Metrics.buttonCornerRadius(proportionalTo: BrowserMetrics.controlHeight)
            applyTitle()
            invalidateIntrinsicContentSize()
        }
        density.start()
        hover = PointerHover(self) { [weak self] _ in self?.updateFill(animated: true) }
        updateFill()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isHighlighted: Bool { didSet { updateFill() } }

    /// The themed title: a plain `title` write would be replaced by the old
    /// text at the next repaint (hover, appearance change).
    override var title: String {
        get { titleText }
        set {
            titleText = newValue
            applyTitle()
            invalidateIntrinsicContentSize()
        }
    }

    override var intrinsicContentSize: NSSize {
        let size = attributedTitle.size()
        return NSSize(width: ceil(size.width) + BrowserMetrics.overlayPadding * 2, height: BrowserMetrics.controlHeight)
    }

    override func viewDidHide() {
        super.viewDidHide()
        hover?.refresh()
    }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        hover?.refresh()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateFill()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        hover?.refresh()
        updateFill()
    }

    private func applyTitle() {
        performWithTheme {
            attributedTitle = NSAttributedString(string: titleText, attributes: [
                .foregroundColor: Palette.textPrimary,
                .font: prominent ? BrowserMetrics.emphasizedFont : BrowserMetrics.bodyFont,
            ])
        }
    }

    private func updateFill(animated: Bool = false) {
        performWithTheme {
            var color = prominent ? Palette.selectionFill : Palette.hoverFill
            if isHighlighted || isHovering {
                color = prominent ? Palette.focusRing.withAlphaComponent(0.35) : Palette.selectionFill
            }
            if let layer { ChromeHover.paint(layer, color, animated: animated && window != nil, pressed: isHighlighted) }
        }
        applyTitle()
    }
}

/// Plain single-line field with no bezel, no focus ring, and a gray
/// selection instead of the accent-colored one.
class ChromeTextField: NSTextField {
    private let density = DensityBinding()
    private var placeholderText = ""
    override init(frame: NSRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        isBordered = false
        isBezeled = false
        drawsBackground = false
        focusRingType = .none
        usesSingleLineMode = true
        lineBreakMode = .byTruncatingTail
        cell?.isScrollable = true
        cell?.wraps = false
        density.update { [weak self] in
            guard let self else { return }
            font = densityFont
            applyPlaceholder()
        }
        density.start()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// The font the field takes at every density change. A subclass with its own size (the omnibar's field) returns it,
    /// so this binding and the subclass's never race to set two fonts (Lucas 2026-11-16: the omnibar's text came back
    /// at the body size after some density switches).
    var densityFont: NSFont { BrowserMetrics.bodyFont }

    /// The text, placeholder and caret colors, read inside the field's theme scope. A field on a surface of its own
    /// (the omnibar's, `AddressField`) returns the inks fitted to it.
    var themedTextColor: NSColor { Palette.textPrimary } // theme-scoped
    var themedPlaceholderColor: NSColor { Palette.textSecondary } // theme-scoped
    var themedCaretColor: NSColor { Palette.caret } // theme-scoped

    func setPlaceholder(_ text: String) {
        placeholderText = text
        applyPlaceholder()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyColors()
    }

    private func applyColors() {
        performWithTheme { textColor = themedTextColor }
        applyPlaceholder()
        applyEditorColors()
    }

    /// Re-reads the field's colors (a change of the surface under it with no appearance change).
    func reapplyColors() { applyColors() }

    private func applyPlaceholder() {
        guard !placeholderText.isEmpty else { return }
        performWithTheme {
            setPlaceholderKeepingEdit(NSAttributedString(string: placeholderText, attributes: [
                .foregroundColor: themedPlaceholderColor,
                .font: font ?? BrowserMetrics.bodyFont,
            ]))
        }
    }

    private func applyEditorColors() {
        guard let editor = currentEditor() as? NSTextView else { return }
        performWithTheme {
            editor.insertionPointColor = themedCaretColor
            editor.selectedTextAttributes = [.backgroundColor: Palette.textSelection]
        }
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { applyEditorColors() }
        return accepted
    }
}
