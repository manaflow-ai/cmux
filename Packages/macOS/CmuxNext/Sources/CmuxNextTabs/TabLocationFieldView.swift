import AppKit
import CmuxNextDesign

/// The selected browser tab's page address, in the strip's free space after
/// the tabs (Arc/Edge style). Quiet on purpose: it sits on the strip's own
/// background with no fill or stroke (only the standard hover fill under the
/// pointer), never animates and never shows load progress (the tab icon
/// does). The host reads in primary text, the path, query and fragment are
/// dimmed, and an http page gets a small "not secure" glyph; https gets
/// none. A click asks the App to focus the address bar
/// (`TabStripIntent.focusLocation`).
///
/// Mouse handling, like the + button's, is the strip's: it forwards presses
/// here with `beginPress` / `trackPress` / `endPress`.
final class TabLocationFieldView: NSView {
    /// What the field shows; nil hides it (`place`).
    var location: TabLocation? {
        didSet {
            guard location != oldValue else { return }
            remeasure()
            updateAccessibility()
        }
    }

    /// One step below the tab titles (`Typography.body`).
    var font = Typography.caption {
        didSet { if font != oldValue { remeasure() } }
    }

    var isHovered = false { didSet { if oldValue != isHovered { needsDisplay = true } } }
    var isPressed = false { didSet { if oldValue != isPressed { needsDisplay = true } } }
    /// A press started on the field and has not ended.
    private(set) var isTracking = false
    var onPress: (() -> Void)?

    /// Width the whole address needs: insets, glyph and text.
    private(set) var naturalWidth: CGFloat = 0
    /// The tooltip registered on the strip (it takes every mouse event, so
    /// tooltips live there). The strip clears `toolTipTag` when it drops all
    /// of its tooltips (`layoutButtonGroup`).
    var toolTipTag: NSView.ToolTipTag?
    private var toolTipKey: (rect: CGRect, text: String)?

    private var horizontalInset: CGFloat { Metrics.space2 }
    private var glyphSpacing: CGFloat { Metrics.space1 }
    private var glyphSize: CGFloat { (font.pointSize * 0.9).rounded() }
    private static let notSecureSymbol = "lock.slash"

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        isHidden = true
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    // MARK: Placement

    /// Shows the field at `frame` (the content view's coordinates), or
    /// hides it for a nil frame, and keeps its tooltip on `host` current.
    func place(_ frame: CGRect?, toolTipHost host: NSView) {
        guard let frame, let location else {
            if !isHidden { isHidden = true }
            isHovered = false
            dropToolTip(from: host)
            return
        }
        if self.frame != frame { self.frame = frame }
        if isHidden { isHidden = false }
        let rect = host.convert(frame, from: superview)
        let text = location.url.absoluteString
        if toolTipTag == nil || toolTipKey?.rect != rect || toolTipKey?.text != text {
            dropToolTip(from: host)
            toolTipTag = host.addToolTip(rect, owner: text as NSString, userData: nil)
            toolTipKey = (rect, text)
        }
    }

    private func dropToolTip(from host: NSView) {
        if let toolTipTag { host.removeToolTip(toolTipTag) }
        toolTipTag = nil
        toolTipKey = nil
    }

    // MARK: Pointer (forwarded by the strip)

    /// Whether `point` (in `view`'s coordinates) is on the shown field.
    func hit(_ point: CGPoint, from view: NSView) -> Bool {
        !isHidden && bounds.contains(convert(point, from: view))
    }

    /// Starts a press when `point` is on the field; returns whether it was.
    func beginPress(at point: CGPoint, from view: NSView) -> Bool {
        guard hit(point, from: view) else { return false }
        isTracking = true
        isPressed = true
        return true
    }

    /// Keeps the pressed look only under the pointer; returns whether a
    /// field press owns the drag.
    func trackPress(at point: CGPoint, from view: NSView) -> Bool {
        guard isTracking else { return false }
        isPressed = hit(point, from: view)
        return true
    }

    /// Ends a press; a release on the field runs `onPress`. Returns whether
    /// a field press was active.
    func endPress(at point: CGPoint, from view: NSView) -> Bool {
        guard isTracking else { return false }
        isTracking = false
        isPressed = false
        if hit(point, from: view) { onPress?() }
        return true
    }

    // MARK: Drawing

    private func remeasure() {
        guard let location else {
            naturalWidth = 0
            return
        }
        let text = (location.displayHost + location.displayRest) as NSString
        let textWidth = ceil(text.size(withAttributes: [.font: font]).width)
        let glyph = location.isSecure ? 0 : glyphSize + glyphSpacing
        naturalWidth = 2 * horizontalInset + glyph + textWidth
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let location else { return }
        performWithTheme {
            if isHovered || isPressed {
                Palette.hoverFill.setFill()
                NSBezierPath(roundedRect: bounds, xRadius: Metrics.itemCornerRadius, yRadius: Metrics.itemCornerRadius).fill()
            }
            var x = horizontalInset
            if !location.isSecure {
                drawNotSecureGlyph(at: x, color: Palette.textTertiary)
                x += glyphSize + glyphSpacing
            }
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineBreakMode = .byTruncatingMiddle
            let text = NSMutableAttributedString(
                string: location.displayHost,
                attributes: [.font: font, .foregroundColor: Palette.textPrimary, .paragraphStyle: paragraph]
            )
            text.append(NSAttributedString(
                string: location.displayRest,
                attributes: [.font: font, .foregroundColor: Palette.textTertiary, .paragraphStyle: paragraph]
            ))
            let lineHeight = ceil(font.ascender - font.descender + font.leading)
            let rect = CGRect(x: x, y: ((bounds.height - lineHeight) / 2).rounded(),
                              width: max(0, bounds.width - x - horizontalInset), height: lineHeight)
            text.draw(in: rect)
        }
    }

    private func drawNotSecureGlyph(at x: CGFloat, color: NSColor) {
        let config = NSImage.SymbolConfiguration(pointSize: glyphSize, weight: .regular)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        guard let symbol = NSImage(systemSymbolName: Self.notSecureSymbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(config) else { return }
        let size = symbol.size
        let ratio = min(glyphSize / max(size.width, 1), glyphSize / max(size.height, 1), 1)
        let drawSize = CGSize(width: size.width * ratio, height: size.height * ratio)
        let rect = CGRect(x: x + (glyphSize - drawSize.width) / 2, y: (bounds.height - drawSize.height) / 2,
                          width: drawSize.width, height: drawSize.height)
        symbol.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }

    // MARK: Accessibility

    private func updateAccessibility() {
        guard let location else {
            setAccessibilityLabel(nil)
            setAccessibilityHelp(nil)
            return
        }
        var parts = [Strings.axLocation(location.displayHost)]
        if !location.isSecure { parts.append(Strings.axNotSecure) }
        setAccessibilityLabel(parts.joined(separator: ", "))
        setAccessibilityHelp(location.url.absoluteString)
    }

    override func accessibilityPerformPress() -> Bool {
        onPress?()
        return true
    }
}
