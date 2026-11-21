import AppKit
import CmuxNextDesignTokens

/// What every native tooltip draws on its glass (``TooltipMetrics``): the text, regular 12 pt in the
/// tooltip ink, wrapping past ``TooltipMetrics/maxWidth``, then the shortcut's keys on the dialogs'
/// keycap plate (``CmuxDialogKeycapView``, ``CmuxDialogKeycapStyle/linearKbd``), centred on the first
/// line and inset ``TooltipMetrics/keycapInset`` from the top and the end, so its corner is
/// concentric with the tooltip's. ``TooltipPanel`` (a view's themed tooltip) and ``WebPopupHost`` (a
/// page's tooltip shown past its window's edge) both draw it, so the two never differ.
@MainActor
final class TooltipContentView: NSView {
    let text = ChromeLabel(wrappingLabelWithString: "")
    /// The keycap of the shortcut; nil while there is none.
    private(set) var keycap: CmuxDialogKeycapView?
    private var shortcut: String?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        text.isSelectable = false
        text.drawsBackground = false
        text.maximumNumberOfLines = 0
        text.translatesAutoresizingMaskIntoConstraints = true
        addSubview(text)
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") } // crash-allow: never decoded from a nib

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// The person's Interface Size.
    static var scale: CGFloat { Typography.userScale }

    /// The tooltip's font: regular, the detail step of the type scale.
    static var font: NSFont { Typography.system(.default, size: TooltipMetrics.fontSize * scale, weight: .regular) }

    /// Shows `value` and, when it is not empty, `shortcut`'s keys on a keycap.
    func set(text value: String, shortcut: String?) {
        text.font = Self.font
        text.stringValue = value
        let keys = shortcut?.trimmingCharacters(in: .whitespacesAndNewlines)
        let next = keys?.isEmpty == false ? keys : nil
        if next != self.shortcut || (next != nil && keycap == nil) {
            keycap?.removeFromSuperview()
            keycap = next.map { keys in
                let made = CmuxDialogKeycapView(keys, style: .linearKbd, cornerRadius: TooltipMetrics.keycapRadius * Self.scale)
                made.translatesAutoresizingMaskIntoConstraints = true
                addSubview(made)
                return made
            }
            self.shortcut = next
        }
        needsLayout = true
    }

    /// Colors the text (`ink`) and the keycap (its plate the ink, faint; its keys `hint`).
    func paint(ink: NSColor, hint: NSColor) {
        text.textColor = ink
        keycap?.paint(ink: ink, glyph: hint)
    }

    /// The keycap's size, zero without one.
    private var keycapSize: NSSize {
        guard let keycap else { return .zero }
        let height = TooltipMetrics.keycapHeight * Self.scale
        return NSSize(width: keycap.width(forHeight: height), height: height)
    }

    /// The surface's size for the current text: as narrow as its text, at most `maxWidth` wide. A wrapped tooltip
    /// keeps the line count it has at `maxWidth` and takes the narrowest width that holds it, so its lines come out
    /// even and no empty room stands beside them (David Beyer, 2026-11-20: tooltips "look strangely wide"; the
    /// pages' `text-wrap: balance` and ui/tooltipFit.ts do the same).
    func fittingSurfaceSize(maxWidth: CGFloat = TooltipMetrics.maxWidth * TooltipContentView.scale) -> NSSize {
        let scale = Self.scale
        let padBlock = TooltipMetrics.paddingBlock * scale
        let padInline = TooltipMetrics.paddingInline * scale
        let key = keycapSize
        // With a keycap, the end's room is the keycap's inset, and the gap sits between it and the text.
        let trailing = keycap == nil ? padInline : TooltipMetrics.keycapInset * scale + key.width + TooltipMetrics.keycapGap * scale
        let textSize = fitText(within: max(1, maxWidth - padInline - trailing))
        // One line is one height, keycap or not: the line height, or the keycap and its inset.
        let line = max(textSize.height, TooltipMetrics.lineHeight * scale)
        let minHeight = keycap == nil ? 0 : key.height + TooltipMetrics.keycapInset * scale * 2
        return NSSize(width: ceil(padInline + textSize.width + trailing),
                      height: ceil(max(line + padBlock * 2, minHeight)))
    }

    /// The text's size at the narrowest wrap width, at most `limit`, that keeps the line count it has at `limit`
    /// (a bisection to half a point, about ten measures; a tooltip shows a few times a minute, never per frame).
    private func fitText(within limit: CGFloat) -> NSSize {
        text.preferredMaxLayoutWidth = limit
        let full = text.fittingSize
        // `fits` keeps the line count, `tooNarrow` does not (zero: nothing narrower is known). The midpoint is not
        // rounded, so it always lies strictly between the two and the gap halves every pass: a rounded midpoint
        // can land on `fits` itself and never narrow the gap.
        var tooNarrow: CGFloat = 0, fits = limit
        while fits - tooNarrow > 0.5 {
            let middle = (tooNarrow + fits) / 2
            text.preferredMaxLayoutWidth = middle
            if text.fittingSize.height <= full.height + 0.5 { fits = middle } else { tooNarrow = middle }
        }
        let width = min(limit, ceil(fits))
        text.preferredMaxLayoutWidth = width
        return NSSize(width: width, height: full.height)
    }

    override func layout() {
        super.layout()
        let scale = Self.scale
        let padInline = TooltipMetrics.paddingInline * scale
        let key = keycapSize
        let trailing = keycap == nil ? padInline : TooltipMetrics.keycapInset * scale + key.width + TooltipMetrics.keycapGap * scale
        text.preferredMaxLayoutWidth = max(1, bounds.width - padInline - trailing)
        // The label's frame: its lines plus its own line padding (LabelText.padding) each side of the glyphs.
        let textSize = text.fittingSize
        // The text sits in the middle of the surface; with one line that centres it on the keycap.
        let middleY = (bounds.height - textSize.height) / 2
        let textY = middleY.rounded()
        // The frame starts the label's padding early, so its glyphs (not its frame) start at the inline padding
        // and end where fittingSurfaceSize measured them, the keycap gap before the keycap. The width is not rounded
        // up: the origin is whole, so the glyphs stay sharp, and a rounded width would reach past the gap.
        text.frame = NSRect(x: padInline - LabelText.padding, y: textY, width: textSize.width, height: ceil(textSize.height))
        if let keycap {
            // On the first line: centred on it, as a menu's shortcut is. The label's own line height (the font's, in
            // whole points), not the nominal ``TooltipMetrics/lineHeight``; and from the text's unrounded place, so
            // an odd line (15 pt at 12 pt) does not round the text and then the keycap down a point each.
            let firstLine = min(textSize.height, text.naturalSize.height)
            let y = max(TooltipMetrics.keycapInset * scale, (middleY + (firstLine - key.height) / 2).rounded())
            keycap.frame = NSRect(x: bounds.width - TooltipMetrics.keycapInset * scale - key.width, y: y,
                                  width: key.width, height: key.height)
        }
    }
}
