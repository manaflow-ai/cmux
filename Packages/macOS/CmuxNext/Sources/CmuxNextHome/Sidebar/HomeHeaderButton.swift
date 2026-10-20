import AppKit
import CmuxNextDesign
import QuartzCore

/// A quiet icon button of the Home list's header (compose, the Unread toggle, the collapsed
/// search), the composer chips' rule: no pill at rest, the theme's soft hover pill under the
/// pointer, the pressed fill and a tiny shrink while held. The glyph is the theme's secondary
/// text; a toggle that is on draws its filled glyph in the theme's accent, never the system blue.
final class HomeHeaderButton: NSButton {
    /// The pressed scale (the composer chip presses to 0.975; a 28 pt button needs a little more to show).
    static let pressScale: CGFloat = 0.94

    private let symbol: String
    /// The glyph while `isOn` (a toggle's filled glyph); nil for a plain button.
    private let onSymbol: String?
    private(set) lazy var hover = ChromeHover(self, cornerRadius: 0, behindContent: true)
    private var followsPointer = false
    /// A right-click menu (compose: New Chief, Invite).
    var contextMenu: (() -> NSMenu?)?

    /// A toggle's state: the filled glyph in the accent, and the accessibility value.
    var isOn = false {
        didSet {
            guard isOn != oldValue else { return }
            renderSymbol()
            applyTint()
            setAccessibilityValue(isOn ? 1 : 0)
        }
    }

    /// The glyph's point size; the header shrinks it with the button at narrow widths.
    private var glyphSize: CGFloat = 0
    private var glyphName = ""

    init(symbol: String, onSymbol: String? = nil, label: String, identifier: String) {
        self.symbol = symbol
        self.onSymbol = onSymbol
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

    /// 14 pt in a 28 pt button, smaller with a smaller button.
    private func renderSymbol() {
        let size = max(10, (bounds.height / 2).rounded())
        let name = isOn ? (onSymbol ?? symbol) : symbol
        guard size != glyphSize || name != glyphName else { return }
        glyphSize = size
        glyphName = name
        image = Self.centredSymbol(name, size: size)
    }

    private static var centred: [String: NSImage] = [:]

    /// Symbol `name` at `size` with what it draws centred in its canvas, as a template (the tint
    /// still applies). SF Symbols centre their layout box, not their ink: compose's pencil tip
    /// lifts its box, so its square sat 1.75 pt below the other header glyphs. Cached per name
    /// and size (a few small images).
    static func centredSymbol(_ name: String, size: CGFloat) -> NSImage? {
        let key = "\(name)@\(size)"
        if let cached = centred[key] { return cached }
        guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: size, weight: .regular)) else { return nil }
        var proposed = CGRect(origin: .zero, size: symbol.size)
        guard let bitmap = symbol.cgImage(forProposedRect: &proposed, context: nil, hints: nil), let ink = inkBounds(bitmap) else {
            return symbol
        }
        let scale = CGFloat(bitmap.width) / max(1, symbol.size.width)
        // How far the ink's centre is from the canvas's, in points (x right, y down from the top).
        let dx = (symbol.size.width / 2 - ink.midX / scale).snapped(scale: scale)
        let dy = (symbol.size.height / 2 - ink.midY / scale).snapped(scale: scale)
        // A canvas grown on both sides by the shift, so the moved ink is never clipped.
        let canvas = NSSize(width: symbol.size.width + 2 * abs(dx), height: symbol.size.height + 2 * abs(dy))
        let result = NSImage(size: canvas, flipped: true) { _ in
            symbol.draw(in: NSRect(x: abs(dx) + dx, y: abs(dy) + dy, width: symbol.size.width, height: symbol.size.height),
                        from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            return true
        }
        result.isTemplate = true
        centred[key] = result
        return result
    }

    /// The pixel rect (origin top-left) of `image`'s visible pixels, nil when it draws nothing.
    static func inkBounds(_ image: CGImage) -> CGRect? {
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height)
        let drawn: Bool = pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                                          bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            // The glyph's ink over white: a drawn pixel is a dark one.
            context.setFillColor(gray: 1, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        var minX = width, minY = height, maxX = -1, maxY = -1
        for y in 0..<height {
            for x in 0..<width where pixels[y * width + x] < 224 {
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= 0 else { return nil }
        return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }

    /// The glyph's colour in the view's theme scope (also on a theme or appearance change).
    func applyTint() {
        contentTintColor = performWithTheme { isOn ? Palette.accentFill : Palette.textSecondary }
        hover.refresh(animated: false)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
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
}

private extension CGFloat {
    /// Rounded to the nearest device pixel at `scale` (pixels per point).
    func snapped(scale: CGFloat) -> CGFloat { scale > 0 ? (self * scale).rounded() / scale : self }
}
