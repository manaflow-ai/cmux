import AppKit
import CmuxNextDesign
import QuartzCore

/// A quiet icon button of the Home list's header (compose, the Unread toggle, the collapsed
/// search), the composer chips' rule: no pill at rest, the theme's soft hover pill under the
/// pointer, the pressed fill and a tiny shrink while held. The glyph is the theme's secondary
/// text; a toggle that is on draws its filled glyph in the theme's accent, never the system blue.
/// A `glass` button sits on a glass circle its host lays under it (Messages' filter): its glyph
/// is the theme's primary text, as Messages' white glyph on its glass.
final class HomeHeaderButton: ClickableButton {
    /// The pressed scale (the composer chip presses to 0.975; a 28 pt button needs a little more to show).
    static let pressScale: CGFloat = 0.94

    private let symbol: String
    /// The glyph while `isOn` (a toggle's filled glyph); nil for a plain button.
    private let onSymbol: String?
    /// The button sits on glass: the glyph is the primary text.
    private let glass: Bool
    private(set) lazy var hover = ChromeHover(self, cornerRadius: 0, behindContent: true)
    private var followsPointer = false
    /// A right-click menu (compose: New Chief, Invite).
    var contextMenu: (() -> NSMenu?)?

    /// A toggle's state: the filled glyph in the accent, and the accessibility value.
    var isOn = false {
        didSet {
            guard isOn != oldValue else { return }
            applyTint()
            setAccessibilityValue(isOn ? 1 : 0)
        }
    }

    /// The glyph's point size; the header shrinks it with the button at narrow widths.
    private(set) var glyphSize: CGFloat = 0
    /// The glyph's symbol name at the last render.
    private(set) var glyphName = ""
    /// The tint the glyph image was built for (`renderSymbol`): the theme's secondary text, the
    /// lit glyph while on.
    private(set) var glyphTint: NSColor?

    init(symbol: String, onSymbol: String? = nil, label: String, identifier: String, glass: Bool = false) {
        self.symbol = symbol
        self.onSymbol = onSymbol
        self.glass = glass
        super.init(frame: .zero)
        isBordered = false
        bezelStyle = .regularSquare
        imagePosition = .imageOnly
        imageScaling = .scaleNone
        setAccessibilityLabel(label)
        setAccessibilityIdentifier(identifier)
        if onSymbol != nil {
            setAccessibilitySubrole(.toggle)
            setAccessibilityValue(0)
        }
        themedToolTip = label
        hover.followPointer(isHoverable: { [weak self] in self?.isEnabled ?? false })
        followsPointer = true
        applyTint()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var mouseDownCanMoveWindow: Bool { false }

    override func layout() {
        super.layout()
        layer?.cornerRadius = bounds.height / 2
        renderSymbol()
    }

    /// A new size re-renders the glyph at once: the header sets the frame in its own layout pass,
    /// and the glyph must not wait for this button's own `layout()` (live-qa, nightly 3a63d6d: on
    /// some launches no compose or filter glyph drew at all until an appearance switch).
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        renderSymbol()
    }

    /// The glyph image and its tint: half the button's height (14 pt in a 28 pt button), in
    /// `glyphTint`. A new image whenever the size, the glyph or the colour changes, so a theme or
    /// light/dark switch redraws the glyph, never leaving the old drawing (or none) on screen.
    private func renderSymbol() {
        let size = max(10, (bounds.height / 2).rounded())
        let name = isOn ? (onSymbol ?? symbol) : symbol
        let tint = performWithTheme { isOn ? Palette.litGlyph : glass ? Palette.textPrimary : Palette.textSecondary }
        guard image == nil || size != glyphSize || name != glyphName || tint != glyphTint else { return }
        glyphSize = size
        glyphName = name
        glyphTint = tint
        image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: size, weight: .regular))
        contentTintColor = tint
        needsDisplay = true
    }

    /// The glyph's colour in the view's theme scope (also on a theme or appearance change): the
    /// image is rebuilt in it.
    func applyTint() {
        renderSymbol()
        hover.refresh(animated: false)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTint()
    }

    /// A move into a window can change the scope (`performWithTheme` resolves through the window).
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyTint()
    }

    /// Shown again (itself or an ancestor): a theme change while hidden is drawn now, even one whose
    /// repaint never reached this button.
    override func viewDidUnhide() {
        super.viewDidUnhide()
        applyTint()
    }

    override var isEnabled: Bool {
        didSet { if followsPointer, isEnabled != oldValue { hover.pointer?.refresh() } }
    }

    /// The press: the pressed fill and the shrink at once, both gone on release.
    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        setPressed(true)
        defer { setPressed(false) }
        super.mouseDown(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? { contextMenu?() ?? super.menu(for: event) }

    private func setPressed(_ pressed: Bool) {
        hover.state.pressed = pressed
        guard let layer else { return }
        let w = bounds.width / 2, h = bounds.height / 2
        let s = pressed ? Self.pressScale : 1
        // The backing layer's anchor is its corner: scale about the centre.
        let shrink = CATransform3DConcat(CATransform3DConcat(CATransform3DMakeTranslation(-w, -h, 0), CATransform3DMakeScale(s, s, 1)),
                                         CATransform3DMakeTranslation(w, h, 0))
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.transform = pressed ? shrink : CATransform3DIdentity
        CATransaction.commit()
    }

    #if DEBUG || CMUX_BENCH_HOOKS
    /// `debug.home.sidebar_fixture`: whether the glyph can show (shown, a frame, an image and
    /// its point size, the tint as sRGB components, the backing layer's drawn contents).
    var debugState: [String: Any] {
        let tint = contentTintColor?.usingColorSpace(.sRGB)
        return ["id": accessibilityIdentifier(), "hidden": isHidden,
                "frame": [frame.minX, frame.minY, frame.width, frame.height].map(Double.init),
                "image": image != nil, "glyphSize": Double(glyphSize), "glyph": glyphName,
                "tint": tint.map { [$0.redComponent, $0.greenComponent, $0.blueComponent, $0.alphaComponent].map(Double.init) } ?? NSNull(),
                "appearance": effectiveAppearance.name.rawValue,
                "layerContents": layer?.contents != nil, "needsDisplay": needsDisplay]
    }
    #endif
}
