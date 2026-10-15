import AppKit
import CmuxNextWakeups
import CmuxNextDesign
import CmuxNextIcons

/// Borderless icon button with gray hover and press fills (no accent color).
final class ChromeIconButton: NSButton {
    private let density = DensityBinding()
    private var iconName = IconName.placeholder
    private var iconLabel = ""
    /// Where the pointer is now (`OmnibarPointer`); a disabled button shows none.
    private var hover: PointerHover?
    var isHovering: Bool { hover?.isHovering ?? false }

    /// Toolbar buttons use the omnibar geometry (`OmnibarStyle`); others the
    /// compact overlay size.
    private let isToolbar: Bool
    /// False for the navigation buttons (Back, Forward, Reload/Stop): their
    /// icons say what they do, so hover shows no tooltip (Lawrence
    /// 2026-10-13). The accessibility label stays.
    private let showsToolTip: Bool
    /// A menu for right-click and long-press (Back / Forward entries).
    var menuProvider: (() -> NSMenu?)?
    private let holdTimer = DemandTimer(owner: "ChromeIconButton.hold")
    private var showedHoldMenu = false

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
            density.bind(widthAnchor.constraint(equalToConstant: 0)) { toolbar ? OmnibarStyle.buttonSize : BrowserMetrics.controlHeight },
            density.bind(heightAnchor.constraint(equalToConstant: 0)) { toolbar ? OmnibarStyle.buttonSize : BrowserMetrics.controlHeight },
        ])
        density.update { [weak self] in
            guard let self else { return }
            layer?.cornerRadius = isToolbar ? OmnibarStyle.buttonCornerRadius : BrowserMetrics.controlCornerRadius
            applyIcon()
        }
        density.start()
        hover = PointerHover(self) { [weak self] _ in self?.updateFill(animated: true) }
        hover?.isHoverable = { [weak self] in self?.isEnabled ?? false }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Unchanged icon and label keep the current image: a new NSImage
    /// makes AppKit lay out and redraw the button.
    func setIcon(_ icon: IconName, label: String) {
        guard icon != iconName || label != iconLabel || image == nil else { return }
        iconName = icon
        iconLabel = label
        applyIcon()
    }

    private func applyIcon() {
        let label = iconLabel
        let side = CGFloat.iconRowSize(forLabelPointSize: isToolbar ? OmnibarStyle.buttonSymbolSize : BrowserMetrics.symbolPointSize)
        let icon = NSImage.icon(iconName, size: side)
        icon.accessibilityDescription = label
        image = icon
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
        menuProvider?() ?? super.menu(for: event)
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
        if menuProvider != nil, isEnabled {
            holdTimer.schedule(after: .milliseconds(400)) { @MainActor [weak self] in self?.showHoldMenu() }
        }
        super.mouseDown(with: event)
        holdTimer.cancel()
    }

    override func sendAction(_ action: Selector?, to target: Any?) -> Bool {
        guard !showedHoldMenu else { return false }
        return super.sendAction(action, to: target)
    }

    private func showHoldMenu() {
        guard let menu = menuProvider?() else { return }
        showedHoldMenu = true
            menu.popUp(positioning: nil, at: CmuxPopoverAnchor.menuPoint(in: self, gap: 2), in: self)
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
            } else if isHighlighted || isOn {
                Palette.selectionFill
            } else if isHovering {
                Palette.hoverFill
            } else {
                .clear
            }
            // Hover eases in and clears at once; a press shows at once (ChromeHover.fade).
            if let layer { ChromeHover.paint(layer, color, animated: animated && window != nil, pressed: isHighlighted) }
            contentTintColor = isToolbar ? Palette.textPrimary : Palette.textSecondary
        }
    }
}

/// Text button for prompts and error pages. `prominent` uses a stronger
/// gray fill instead of the system accent.
class ChromeTextButton: NSButton {
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
            layer?.cornerRadius = BrowserMetrics.controlCornerRadius
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
            font = BrowserMetrics.bodyFont
            applyPlaceholder()
        }
        density.start()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

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
        performWithTheme { textColor = Palette.textPrimary }
        applyPlaceholder()
        applyEditorColors()
    }

    private func applyPlaceholder() {
        guard !placeholderText.isEmpty else { return }
        performWithTheme {
            setPlaceholderKeepingEdit(NSAttributedString(string: placeholderText, attributes: [
                .foregroundColor: Palette.textSecondary,
                .font: font ?? BrowserMetrics.bodyFont,
            ]))
        }
    }

    private func applyEditorColors() {
        guard let editor = currentEditor() as? NSTextView else { return }
        performWithTheme {
            editor.insertionPointColor = Palette.caret
            editor.selectedTextAttributes = [.backgroundColor: Palette.textSelection]
        }
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { applyEditorColors() }
        return accepted
    }
}
