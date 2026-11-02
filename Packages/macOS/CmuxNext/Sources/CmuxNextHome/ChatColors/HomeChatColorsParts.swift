import AppKit
import CmuxHomeRender
import CmuxNextDesign

/// The Chat Colors… preview: a sample of their message and of yours, in the colours the chat would
/// draw with, on the chat's page colour.
@MainActor
final class HomeChatColorsPreviewView: NSView {
    private let received = HomeChatColorsBubble(HomeChatColorsStrings.sampleReceived)
    private let sent = HomeChatColorsBubble(HomeChatColorsStrings.sampleSent)

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 10
        translatesAutoresizingMaskIntoConstraints = false
        for bubble in [received, sent] { addSubview(bubble) }
        NSLayoutConstraint.activate([
            received.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            received.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            received.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12 - 40),
            sent.topAnchor.constraint(equalTo: received.bottomAnchor, constant: 6),
            sent.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            sent.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 12 + 40),
            sent.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(HomeChatColorsStrings.previewLabel)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    private var background: NSColor = .clear

    func show(_ shown: HomeChatColorsPreview) {
        background = shown.background
        received.show(shown.received)
        sent.show(shown.sent)
        needsDisplay = true
    }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() { layer?.backgroundColor = background.cgColor }
}

/// One sample message: a capsule in the bubble colour around its text.
@MainActor
final class HomeChatColorsBubble: NSView {
    private let label: NSTextField

    init(_ text: String) {
        label = NSTextField(labelWithString: text)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerCurve = .continuous
        translatesAutoresizingMaskIntoConstraints = false
        label.font = NSFont.systemFont(ofSize: TypeScale.body)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setAccessibilityElement(false)
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 7),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -7),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private var fill: NSColor = .clear

    /// The text, for tests.
    var text: String { label.stringValue }
    /// The colours shown, for tests.
    private(set) var shown: HomeChatColorsPreview.Pair?

    func show(_ pair: HomeChatColorsPreview.Pair) {
        shown = pair
        fill = pair.fill
        label.textColor = pair.text
        needsDisplay = true
    }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() { layer?.backgroundColor = fill.cgColor }

    override func layout() {
        super.layout()
        layer?.cornerRadius = bounds.height / 2
    }
}

/// A swatch; nil is Default (a bubble) or Automatic (text), drawn as a slashed circle (or a text
/// glyph). Selected draws an accent ring just outside it, as Messages does.
@MainActor
final class HomeChatColorSwatch: NSControl {
    static let size: CGFloat = 18

    let color: HomeColor?
    private let auto: Bool
    private let glyph = NSImageView()
    var onPick: (() -> Void)?

    var isSelected = false {
        didSet {
            guard isSelected != oldValue else { return }
            updateRing()
            setAccessibilitySelected(isSelected)
        }
    }

    init(color: HomeColor?, auto: Bool) {
        self.color = color
        self.auto = auto
        super.init(frame: NSRect(x: 0, y: 0, width: Self.size, height: Self.size))
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Self.size),
            heightAnchor.constraint(equalToConstant: Self.size),
        ])
        wantsLayer = true
        layer?.masksToBounds = false
        if color == nil {
            let symbol = NSImage(systemSymbolName: auto ? "textformat" : "circle.slash", accessibilityDescription: nil)
            glyph.image = symbol?.withSymbolConfiguration(.init(pointSize: TypeScale.caption, weight: .regular))
            glyph.contentTintColor = .secondaryLabelColor
            glyph.frame = bounds
            glyph.autoresizingMask = [.width, .height]
            glyph.imageAlignment = .alignCenter
            addSubview(glyph)
        }
        let name = color?.hex ?? (auto ? HomeChatColorsStrings.automatic : HomeChatColorsStrings.styleDefault)
        themedToolTip = name
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(name)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // Keyboard navigation (System Settings > Keyboard) tabs to a swatch and Space presses it, as it
    // does a SwiftUI button; a click never takes focus.
    override var acceptsFirstResponder: Bool { NSApp.isFullKeyboardAccessEnabled }
    override var canBecomeKeyView: Bool { NSApp.isFullKeyboardAccessEnabled }
    override var focusRingMaskBounds: NSRect { bounds }
    override func drawFocusRingMask() { NSBezierPath(ovalIn: bounds).fill() }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func keyDown(with event: NSEvent) {
        guard event.charactersIgnoringModifiers == " " else { return super.keyDown(with: event) }
        if isEnabled { onPick?() }
    }

    override func draw(_ dirtyRect: NSRect) {
        let circle = bounds
        if let color {
            color.nsColor.setFill()
            NSBezierPath(ovalIn: circle).fill()
            NSColor.labelColor.withAlphaComponent(0.18).setStroke()
            stroke(circle, width: 1)
        } else {
            NSColor.secondaryLabelColor.setStroke()
            stroke(circle, width: 1)
        }
    }

    /// A ring of `width` inside `rect` (SwiftUI's strokeBorder).
    private func stroke(_ rect: NSRect, width: CGFloat) {
        let path = NSBezierPath(ovalIn: rect.insetBy(dx: width / 2, dy: width / 2))
        path.lineWidth = width
        path.stroke()
    }

    // The selection ring sits 3 points outside the swatch, outside its bounds, so a layer draws it.
    private lazy var ring: CAShapeLayer = {
        let ring = CAShapeLayer()
        ring.fillColor = nil
        ring.lineWidth = 2
        layer?.addSublayer(ring)
        return ring
    }()

    override func layout() {
        super.layout()
        updateRing()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateRing()
    }

    private func updateRing() {
        guard layer != nil else { return }
        ring.isHidden = !isSelected
        ring.frame = bounds
        ring.path = CGPath(ellipseIn: bounds.insetBy(dx: -3 + 1, dy: -3 + 1), transform: nil)
        effectiveAppearance.performAsCurrentDrawingAppearance {
            ring.strokeColor = NSColor.controlAccentColor.cgColor
        }
    }

    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        guard isEnabled, bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        onPick?()
    }

    override func accessibilityPerformPress() -> Bool {
        onPick?()
        return true
    }
}

/// Any colour (the system colour panel), starting from the one shown.
@MainActor
final class HomeChatColorWell: NSColorWell {
    var onPick: ((NSColor) -> Void)?

    init() {
        super.init(frame: .zero)
        supportsAlpha = false
        target = self
        action = #selector(picked)
        themedToolTip = HomeChatColorsStrings.custom
        setAccessibilityLabel(HomeChatColorsStrings.custom)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Shows `color` unless it is already shown (a drag in the colour panel round-trips through the store).
    func show(_ color: NSColor) {
        guard HomeColor(color) != HomeColor(self.color) else { return }
        self.color = color
    }

    @objc private func picked() { onPick?(color) }
}
