import AppKit
import CmuxNextDesign

/// Borderless icon button with gray hover and press fills (no accent color).
final class ChromeIconButton: NSButton {
    private var isHovering = false { didSet { updateFill() } }
    private var tracking: NSTrackingArea?

    init(symbol: String, label: String, action: Selector?, target: AnyObject?) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        isBordered = false
        bezelStyle = .regularSquare
        imagePosition = .imageOnly
        setSymbol(symbol, label: label)
        contentTintColor = Palette.textSecondary
        self.action = action
        self.target = target
        toolTip = label
        setAccessibilityLabel(label)
        wantsLayer = true
        layer?.cornerRadius = Metrics.itemCornerRadius
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: BrowserMetrics.controlHeight),
            heightAnchor.constraint(equalToConstant: BrowserMetrics.controlHeight),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func setSymbol(_ symbol: String, label: String) {
        let configuration = NSImage.SymbolConfiguration(pointSize: BrowserMetrics.symbolPointSize, weight: .medium)
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
        layer?.cornerRadius = BrowserMetrics.controlCornerRadius
        attributedTitle = NSAttributedString(string: title, attributes: [
            .foregroundColor: Palette.textPrimary,
            .font: prominent ? BrowserMetrics.emphasizedFont : BrowserMetrics.bodyFont,
        ])
        heightAnchor.constraint(equalToConstant: BrowserMetrics.controlHeight).isActive = true
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
        font = BrowserMetrics.bodyFont
        textColor = Palette.textPrimary
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func setPlaceholder(_ text: String) {
        placeholderAttributedString = NSAttributedString(string: text, attributes: [
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
