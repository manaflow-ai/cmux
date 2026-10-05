import AppKit
import CmuxNextWakeups
import CmuxNextDesign

/// Borderless icon button with gray hover and press fills (no accent color).
final class ChromeIconButton: NSButton {
    private let density = DensityBinding()
    private var symbolName = ""
    private var symbolLabel = ""
    private var isHovering = false { didSet { updateFill() } }
    private var tracking: NSTrackingArea?

    /// Toolbar buttons use the omnibar geometry (`OmnibarStyle`); others the
    /// compact overlay size.
    private let isToolbar: Bool
    /// A menu for right-click and long-press (Back / Forward entries).
    var menuProvider: (() -> NSMenu?)?
    private let holdTimer = DemandTimer(owner: "ChromeIconButton.hold")
    private var showedHoldMenu = false

    init(symbol: String, label: String, action: Selector?, target: AnyObject?, toolbar: Bool = false) {
        isToolbar = toolbar
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        isBordered = false
        bezelStyle = .regularSquare
        imagePosition = .imageOnly
        symbolName = symbol
        symbolLabel = label
        self.action = action
        self.target = target
        toolTip = label
        setAccessibilityLabel(label)
        wantsLayer = true
        NSLayoutConstraint.activate([
            density.bind(widthAnchor.constraint(equalToConstant: 0)) { toolbar ? OmnibarStyle.buttonSize : BrowserMetrics.controlHeight },
            density.bind(heightAnchor.constraint(equalToConstant: 0)) { toolbar ? OmnibarStyle.buttonSize : BrowserMetrics.controlHeight },
        ])
        density.update { [unowned self] in
            layer?.cornerRadius = isToolbar ? OmnibarStyle.buttonCornerRadius : BrowserMetrics.controlCornerRadius
            applySymbol()
        }
        density.start()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func setSymbol(_ symbol: String, label: String) {
        symbolName = symbol
        symbolLabel = label
        applySymbol()
    }

    private func applySymbol() {
        let symbol = symbolName
        let label = symbolLabel
        let configuration = isToolbar
            ? NSImage.SymbolConfiguration(pointSize: OmnibarStyle.buttonSymbolSize, weight: .regular)
            : NSImage.SymbolConfiguration(pointSize: BrowserMetrics.symbolPointSize, weight: .medium)
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)?
            .withSymbolConfiguration(configuration)
        toolTip = label
        setAccessibilityLabel(label)
    }

    override var isEnabled: Bool {
        didSet { alphaValue = isEnabled ? 1 : 0.35; updateFill() }
    }

    override var isHighlighted: Bool {
        didSet { updateFill() }
    }

    /// A toggle that is on (design mode, open DevTools) keeps the pressed
    /// fill; the app accent is a neutral gray, so a tint would not read.
    var isOn = false {
        didSet { if isOn != oldValue { updateFill() } }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { isHovering = true }
    override func mouseExited(with event: NSEvent) { isHovering = false }

    override func menu(for event: NSEvent) -> NSMenu? {
        menuProvider?() ?? super.menu(for: event)
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
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: bounds.height + 2), in: self)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateFill()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateFill()
    }

    private func updateFill() {
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
            layer?.backgroundColor = color.cgColor
            contentTintColor = isToolbar ? Palette.textPrimary : Palette.textSecondary
        }
    }
}

/// Text button for prompts and error pages. `prominent` uses a stronger
/// gray fill instead of the system accent.
class ChromeTextButton: NSButton {
    private let density = DensityBinding()
    private let prominent: Bool
    private var isHovering = false { didSet { updateFill() } }
    private var tracking: NSTrackingArea?
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
        density.update { [unowned self] in
            layer?.cornerRadius = BrowserMetrics.controlCornerRadius
            applyTitle()
            invalidateIntrinsicContentSize()
        }
        density.start()
        updateFill()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isHighlighted: Bool { didSet { updateFill() } }

    override var intrinsicContentSize: NSSize {
        let size = attributedTitle.size()
        return NSSize(width: ceil(size.width) + BrowserMetrics.overlayPadding * 2, height: BrowserMetrics.controlHeight)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { isHovering = true }
    override func mouseExited(with event: NSEvent) { isHovering = false }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateFill()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
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

    private func updateFill() {
        performWithTheme {
            var color = prominent ? Palette.selectionFill : Palette.hoverFill
            if isHighlighted || isHovering {
                color = prominent ? Palette.focusRing.withAlphaComponent(0.35) : Palette.selectionFill
            }
            layer?.backgroundColor = color.cgColor
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
        density.update { [unowned self] in
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
            placeholderAttributedString = NSAttributedString(string: placeholderText, attributes: [
                .foregroundColor: Palette.textSecondary,
                .font: font ?? BrowserMetrics.bodyFont,
            ])
        }
    }

    private func applyEditorColors() {
        guard let editor = currentEditor() as? NSTextView else { return }
        performWithTheme {
            editor.insertionPointColor = Palette.textPrimary
            editor.selectedTextAttributes = [.backgroundColor: Palette.textSelection]
        }
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { applyEditorColors() }
        return accepted
    }
}
