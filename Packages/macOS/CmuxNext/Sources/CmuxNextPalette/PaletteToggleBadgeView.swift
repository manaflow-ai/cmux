import AppKit
import CmuxNextDesign

/// The trailing state of a palette row that flips a state (``PaletteToggleStyle``): "On" or "Off"
/// as plain text (with a dot in one style), an "On"/"Off" pill or a checkmark. Never a switch: the
/// row itself flips. Drawn directly (no subviews, no control): the row is a reused table cell and a
/// control there would take clicks and focus.
final class PaletteToggleBadgeView: NSView {
    /// Whether the state is on now.
    var isOn = false {
        didSet { if isOn != oldValue { needsDisplay = true } }
    }
    var style: PaletteToggleStyle = .stateWord {
        didSet {
            guard style != oldValue else { return }
            invalidateIntrinsicContentSize()
            needsDisplay = true
        }
    }

    nonisolated override var isFlipped: Bool { true }

    private var word: String { isOn ? PaletteStrings.on : PaletteStrings.off }

    /// The dot before the word in ``PaletteToggleStyle/stateWordDot``.
    private var dotSide: CGFloat { max(5, round(Typography.caption.pointSize * 0.5)) }

    /// theme-scoped: read inside `performWithTheme` (draw) or for measuring. "On" takes the accent's lit
    /// ink (`litGlyph`, never the raw accent); "Off" the tertiary ink, or the secondary one in
    /// ``PaletteToggleStyle/stateWordStrongOff``.
    private func wordAttributes(on: Bool) -> [NSAttributedString.Key: Any] {
        let ink: NSColor = on ? (style == .wordPill ? Palette.textPrimary : Palette.litGlyph)
            : style == .stateWordStrongOff ? Palette.textSecondary : Palette.textTertiary
        return [.font: Typography.caption, .foregroundColor: ink]
    }

    /// The wider of "On" and "Off", so a row's layout never moves when the state changes.
    private var wordWidth: CGFloat {
        let attributes = wordAttributes(on: true)
        return ceil(max((PaletteStrings.on as NSString).size(withAttributes: attributes).width,
                        (PaletteStrings.off as NSString).size(withAttributes: attributes).width))
    }

    override var intrinsicContentSize: NSSize {
        let height = PaletteLayout.keycapSize
        switch style {
        case .stateWord, .stateWordStrongOff: return NSSize(width: wordWidth, height: height)
        case .stateWordDot: return NSSize(width: dotSide + Metrics.space2 + wordWidth, height: height)
        case .wordPill: return NSSize(width: wordWidth + Metrics.space3 * 2, height: height)
        case .trailingCheck: return NSSize(width: Metrics.iconSize, height: height)
        case .leadingCheck, .titleSuffix, .none: return .zero
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        performWithTheme {
            switch style {
            case .stateWord, .stateWordStrongOff:
                drawWord(rightAt: bounds.maxX)
            case .stateWordDot:
                drawDot()
                drawWord(rightAt: bounds.maxX)
            case .wordPill:
                drawPill()
            case .trailingCheck:
                drawCheck()
            case .leadingCheck, .titleSuffix, .none:
                break
            }
        }
    }

    /// theme-scoped. A dot filled with the lit ink while on, an outline in the tertiary ink while off.
    private func drawDot() {
        let side = dotSide
        let rect = NSRect(x: bounds.minX, y: (bounds.height - side) / 2, width: side, height: side)
        if isOn {
            Palette.litGlyph.setFill()
            NSBezierPath(ovalIn: rect).fill()
        } else {
            Palette.textTertiary.setStroke()
            let ring = NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5))
            ring.lineWidth = 1
            ring.stroke()
        }
    }

    /// theme-scoped. The state word, right-aligned at `right`.
    private func drawWord(rightAt right: CGFloat) {
        let attributes = wordAttributes(on: isOn)
        let size = (word as NSString).size(withAttributes: attributes)
        (word as NSString).draw(at: NSPoint(x: right - size.width, y: (bounds.height - size.height) / 2), withAttributes: attributes)
    }

    /// theme-scoped. An accent pill reading "On", or a gray pill reading "Off".
    private func drawPill() {
        let height = PaletteLayout.keycapSize
        let rect = NSRect(x: 0, y: (bounds.height - height) / 2, width: bounds.width, height: height)
        // A fill, not a lit glyph: the word on it takes the accent's own ink (`onAccent`).
        if isOn { Palette.accentFill.setFill() } else { Palette.hoverFill.setFill() }
        NSBezierPath(roundedRect: rect, xRadius: height / 2, yRadius: height / 2).fill()
        var attributes = wordAttributes(on: isOn)
        if isOn { attributes[.foregroundColor] = Palette.onAccent }
        let size = (word as NSString).size(withAttributes: attributes)
        (word as NSString).draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2), withAttributes: attributes)
    }

    /// theme-scoped. A checkmark while on, in the primary text color.
    private func drawCheck() {
        guard isOn, let image = PaletteText.symbol("checkmark", size: Metrics.iconSize)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [Palette.textPrimary])) else { return }
        let side = Metrics.iconSize
        image.draw(in: NSRect(x: bounds.maxX - side, y: (bounds.height - side) / 2, width: side, height: side))
    }
}
