import AppKit
import CmuxNextDesign

/// Borderless icon button with gray hover and press fills (no accent color).
final class ChromeIconButton: NSButton {
    private let density = DensityBinding()
    private var symbolName = ""
    private var symbolLabel = ""
    private var isHovering = false { didSet { updateFill() } }
    private var tracking: NSTrackingArea?

    /// Toolbar buttons use Helium's geometry (`OmnibarStyle`); others the
    /// compact overlay size.
    private let isToolbar: Bool

    init(symbol: String, label: String, action: Selector?, target: AnyObject?, toolbar: Bool = false) {
        isToolbar = toolbar
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        isBordered = false
        bezelStyle = .regularSquare
        imagePosition = .imageOnly
        symbolName = symbol
        symbolLabel = label
        contentTintColor = Palette.textSecondary
        self.action = action
        self.target = target
        toolTip = label
        setAccessibilityLabel(label)
        wantsLayer = true
        NSLayoutConstraint.activate([
            density.bind(widthAnchor.constraint(equalToConstant: 0)) { toolbar ? OmnibarStyle.buttonSize : BrowserMetrics.controlHeight },
            density.bind(heightAnchor.constraint(equalToConstant: 0)) { toolbar ? OmnibarStyle.buttonSize : BrowserMetrics.controlHeight },
        ])
        if toolbar { contentTintColor = Palette.textPrimary }
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

    private func updateFill() {
        let color: NSColor = if !isEnabled {
            .clear
        } else if isHighlighted {
            Palette.selectionFill
        } else if isHovering {
            Palette.hoverFill
        } else {
            .clear
        }
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = color.cgColor
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
        density.update { [unowned self] in
            layer?.cornerRadius = BrowserMetrics.controlCornerRadius
            attributedTitle = NSAttributedString(string: title, attributes: [
                .foregroundColor: Palette.textPrimary,
                .font: prominent ? BrowserMetrics.emphasizedFont : BrowserMetrics.bodyFont,
            ])
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

    private func updateFill() {
        var color = prominent ? Palette.selectionFill : Palette.hoverFill
        if isHighlighted || isHovering {
            color = prominent ? Palette.focusRing.withAlphaComponent(0.35) : Palette.selectionFill
        }
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = color.cgColor
        }
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
        textColor = Palette.textPrimary
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

    private func applyPlaceholder() {
        guard !placeholderText.isEmpty else { return }
        placeholderAttributedString = NSAttributedString(string: placeholderText, attributes: [
            .foregroundColor: Palette.textSecondary,
            .font: font ?? BrowserMetrics.bodyFont,
        ])
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted, let editor = currentEditor() as? NSTextView {
            editor.insertionPointColor = Palette.textPrimary
            editor.selectedTextAttributes = [.backgroundColor: NSColor(white: 0.5, alpha: 0.35)]
        }
        return accepted
    }
}
