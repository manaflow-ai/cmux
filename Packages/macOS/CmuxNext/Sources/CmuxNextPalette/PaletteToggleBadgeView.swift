import AppKit
import CmuxNextDesign

/// The trailing state of an on/off command's palette row (``PaletteToggleStyle``): a mini switch,
/// a switch with its word, an "On"/"Off" pill or a checkmark. Drawn directly (no subviews, no
/// `NSSwitch`): the row is a reused table cell and a control there would take clicks and focus.
final class PaletteToggleBadgeView: NSView {
    /// Whether the command is on now.
    var isOn = false {
        didSet { if isOn != oldValue { needsDisplay = true } }
    }
    var style: PaletteToggleStyle = .trailingSwitch {
        didSet {
            guard style != oldValue else { return }
            invalidateIntrinsicContentSize()
            needsDisplay = true
        }
    }

    nonisolated override var isFlipped: Bool { true }

    /// The switch's track: 26 by 15 pt at the body text size, the mini `NSSwitch`'s proportions.
    private var trackSize: NSSize {
        let height = max(12, round(Typography.body.pointSize * 1.15))
        return NSSize(width: round(height * 1.73), height: height)
    }

    private var word: String { isOn ? PaletteStrings.on : PaletteStrings.off }

    /// theme-scoped: read inside `performWithTheme` (draw) or for measuring.
    private func wordAttributes(on: Bool) -> [NSAttributedString.Key: Any] {
        [.font: Typography.caption, .foregroundColor: on ? Palette.textPrimary : Palette.textTertiary]
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
        case .trailingSwitch: return NSSize(width: trackSize.width, height: height)
        case .switchWithWord: return NSSize(width: wordWidth + Metrics.space3 + trackSize.width, height: height)
        case .wordPill: return NSSize(width: wordWidth + Metrics.space3 * 2, height: height)
        case .trailingCheck: return NSSize(width: Metrics.iconSize, height: height)
        case .leadingCheck, .titleSuffix, .none: return .zero
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        performWithTheme {
            switch style {
            case .trailingSwitch:
                drawSwitch(in: NSRect(x: bounds.maxX - trackSize.width, y: (bounds.height - trackSize.height) / 2,
                                      width: trackSize.width, height: trackSize.height))
            case .switchWithWord:
                drawWord(rightAt: bounds.maxX - trackSize.width - Metrics.space3)
                drawSwitch(in: NSRect(x: bounds.maxX - trackSize.width, y: (bounds.height - trackSize.height) / 2,
                                      width: trackSize.width, height: trackSize.height))
            case .wordPill:
                drawPill()
            case .trailingCheck:
                drawCheck()
            case .leadingCheck, .titleSuffix, .none:
                break
            }
        }
    }

    /// theme-scoped. An accent track with the knob right while on; a hairline gray track, knob left, while off.
    private func drawSwitch(in track: NSRect) {
        let radius = track.height / 2
        let path = NSBezierPath(roundedRect: track, xRadius: radius, yRadius: radius)
        if isOn {
            Palette.accentFill.setFill()
            path.fill()
        } else {
            Palette.hoverFill.setFill()
            path.fill()
            Palette.separator.setStroke()
            let outline = NSBezierPath(roundedRect: track.insetBy(dx: 0.5, dy: 0.5), xRadius: radius - 0.5, yRadius: radius - 0.5)
            outline.lineWidth = 1
            outline.stroke()
        }
        let inset: CGFloat = 1.5
        let knobSide = track.height - inset * 2
        let knobX = isOn ? track.maxX - inset - knobSide : track.minX + inset
        let knob = NSBezierPath(ovalIn: NSRect(x: knobX, y: track.minY + inset, width: knobSide, height: knobSide))
        (isOn ? Palette.onAccent : Palette.textTertiary).setFill()
        knob.fill()
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
