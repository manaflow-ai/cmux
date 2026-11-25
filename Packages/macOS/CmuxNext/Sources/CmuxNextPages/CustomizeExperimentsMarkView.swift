public import AppKit
import CmuxNextDesign

/// The "Experiment on · #43543" mark at the sidebar's bottom-left (webviews gallery
/// `ui.customize-experiments.mark`), drawn by ``CustomizeExperiments/makeMark(open:)``: it shows while an
/// unmerged pull request's pages are on in this app (`cmux customize use pr:N`) and is hidden, laying
/// out nothing, otherwise. A click on its line opens Settings > Personalization > Customization Library;
/// its Turn Off turns every such entry off through the bundled CLI.
///
/// It is native on purpose: a PR's pages can break any page, Settings included, and the way out must not
/// be drawn by the experiment (Leo, 2026-11-14: "I want people to not accidentally soft lock themselves
/// and like have good recovery options"). It floats over the sidebar on app health's chip (the sidebar
/// cards' veil, caption text, the chip radius; design/app-health.md), never in the footer row's flow
/// (SidebarFooterBand.placeExperimentsMark). No motion.
@MainActor
public final class CustomizeExperimentsMarkView: NSView {
    /// The press on the line.
    var onOpen: (() -> Void)?
    /// The press on Turn Off.
    var onTurnOff: (@MainActor () -> Void)?
    /// The line drawn, nil while hidden.
    public private(set) var line: String?

    private let glass = CardSurfaceView() // concentric-allow: a chip, not a card: it rounds as app health's chip it stacks with (`layout()`)
    private let glyph = NSImageView()
    private let label = ChromeLabel(labelWithString: "")
    private let button = QuietTextButton()
    static let glyphSide: CGFloat = 10

    override public init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        addSubview(glass)
        glyph.image = NSImage(systemSymbolName: "flask", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: Self.glyphSide, weight: TypeScale.regular))
        glyph.setAccessibilityElement(false)
        addSubview(glyph)
        label.font = Typography.caption
        // A narrow sidebar cuts the middle, so both what it is and which PR stay ("Experim…#43543").
        label.lineBreakMode = .byTruncatingMiddle
        label.setAccessibilityElement(false)
        addSubview(label)
        button.onPress = { [weak self] in self?.onTurnOff?() }
        button.setAccessibilityIdentifier("cmux.sidebar.experiments.turnOff")
        addSubview(button)
        isHidden = true
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityIdentifier("cmux.sidebar.experiments")
        applyColors()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Shows `line` with `help` as its tooltip and `turnOff` as its button; nil hides the mark.
    func show(line: String?, help: String, turnOff: String) {
        guard line != self.line else { return }
        self.line = line
        label.stringValue = line ?? ""
        themedToolTip = line == nil ? nil : help
        setAccessibilityLabel(line.map { "\($0). \(help)" })
        button.configure(title: turnOff)
        isHidden = line == nil
        superview?.needsLayout = true
    }

    private var inset: CGFloat { Metrics.space2 }

    override public var fittingSize: NSSize {
        let text = label.fittingSize
        let height = max(text.height + 2 * Metrics.space1, QuietTextButton.height)
        return NSSize(width: inset + Self.glyphSide + Metrics.space1 + text.width + Metrics.space1 + button.fittingWidth + Metrics.space1,
                      height: height)
    }

    override public func layout() {
        super.layout()
        glass.frame = bounds
        glass.cornerRadius = Metrics.chipCornerRadius(height: bounds.height) // radius-allow: the chip's glass, app health's chip shape; Turn Off rounds as a tab // concentric-allow: matches app health's chip beside it
        let side = Self.glyphSide
        glyph.frame = NSRect(x: inset, y: (bounds.height - side) / 2, width: side, height: side)
        let width = button.fittingWidth, height = QuietTextButton.height
        button.frame = NSRect(x: bounds.width - Metrics.space1 - width, y: (bounds.height - height) / 2, width: width, height: height)
        let x = glyph.frame.maxX + Metrics.space1
        let text = label.fittingSize.height
        label.frame = NSRect(x: x, y: (bounds.height - text) / 2, width: max(0, button.frame.minX - Metrics.space1 - x), height: text)
    }

    override public func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    private func applyColors() {
        performWithTheme {
            label.textColor = Palette.textSecondary
            glyph.contentTintColor = Palette.textSecondary
        }
    }

    /// Turn Off takes its own clicks; the rest of the chip is the line's. A hidden mark takes none.
    override public func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        return hit === button || hit.isDescendant(of: button) ? hit : self
    }

    override public var mouseDownCanMoveWindow: Bool { false }
    override public func mouseDown(with event: NSEvent) {}

    override public func mouseUp(with event: NSEvent) {
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        onOpen?()
    }

    override public func accessibilityPerformPress() -> Bool {
        onOpen?()
        return onOpen != nil
    }
}

/// The mark's Turn Off, as the sidebar cards' quiet text buttons (their "Hide"): caption text in the
/// secondary color, primary with the hover fill under the pointer, a button for VoiceOver and Full
/// Keyboard Access. A mouse click never takes the keyboard focus: the mark hides after it.
@MainActor
final class QuietTextButton: NSView {
    var onPress: (() -> Void)?
    private let label = ChromeLabel(labelWithString: "")
    private var isHovered = false { didSet { if isHovered != oldValue { needsDisplay = true } } }
    private var isPressed = false { didSet { if isPressed != oldValue { needsDisplay = true } } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerCurve = .continuous
        label.lineBreakMode = .byClipping
        label.maximumNumberOfLines = 1
        label.setAccessibilityElement(false)
        addSubview(label)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    nonisolated override var wantsUpdateLayer: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    static var font: NSFont { Typography.caption }
    static var height: CGFloat { ceil(font.boundingRectForFont.height) + Metrics.space1 }

    func configure(title: String) {
        label.stringValue = title
        setAccessibilityLabel(title)
        needsLayout = true
        needsDisplay = true
    }

    var fittingWidth: CGFloat {
        label.font = Self.font
        return ceil(label.naturalSize.width) + 2 * Metrics.space1
    }

    override func layout() {
        super.layout()
        layer?.cornerRadius = Metrics.buttonCornerRadius
        label.font = Self.font
        let height = ceil(label.intrinsicContentSize.height)
        label.frame = NSRect(x: Metrics.space1, y: (bounds.height - height) / 2, width: max(0, bounds.width - 2 * Metrics.space1), height: height)
    }

    override func updateLayer() {
        performWithTheme {
            layer?.backgroundColor = (isPressed ? Palette.pressedFill : isHovered ? Palette.hoverFill : .clear).cgColor
            label.textColor = isHovered || isPressed ? Palette.textPrimary : Palette.textSecondary
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas where area.owner === self { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }
    override func mouseDown(with event: NSEvent) { isPressed = true }

    override func mouseUp(with event: NSEvent) {
        isPressed = false
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        onPress?()
    }

    override func accessibilityPerformPress() -> Bool {
        onPress?()
        return onPress != nil
    }
}
