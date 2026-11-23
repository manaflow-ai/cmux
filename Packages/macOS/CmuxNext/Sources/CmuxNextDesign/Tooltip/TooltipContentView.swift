import AppKit
import CmuxNextDesignTokens

/// What every native tooltip draws on its glass (``TooltipMetrics``): the text, regular 12 pt in the
/// tooltip ink, one line that ends in an ellipsis past ``TooltipMetrics/maxWidth``, then the shortcut's keys on the dialogs'
/// keycap plate (``CmuxDialogKeycapView``, ``CmuxDialogKeycapStyle/linearKbd``), centred on the first
/// line and inset ``TooltipMetrics/keycapInset`` from the top and the end, so its corner is
/// concentric with the tooltip's. ``TooltipPanel`` (a view's themed tooltip) and ``WebPopupHost`` (a
/// page's tooltip shown past its window's edge) both draw it, so the two never differ.
@MainActor
final class TooltipContentView: NSView {
    let text = ChromeLabel(labelWithString: "")
    /// The keycap of the shortcut; nil while there is none.
    private(set) var keycap: CmuxDialogKeycapView?
    private var shortcut: String?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        text.isSelectable = false
        text.drawsBackground = false
        // One line (a1315: a tooltip is the control's name and its shortcut): a long name ends in an ellipsis.
        text.maximumNumberOfLines = 1
        text.lineBreakMode = .byTruncatingTail
        text.truncatesLastVisibleLine = true
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

    /// Shows `value`'s first line and, when it is not empty, `shortcut`'s keys on a keycap.
    func set(text value: String, shortcut: String?) {
        text.font = Self.font
        text.stringValue = Self.firstLine(value)
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

    /// The first line of `value`, trimmed: a tooltip is one line, so a second never shows.
    static func firstLine(_ value: String) -> String {
        // main-actor-ok: a tooltip's own string, a line or two of UI text.
        value.split(whereSeparator: \.isNewline).first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
    }

    /// The keycap's size, zero without one.
    private var keycapSize: NSSize {
        guard let keycap else { return .zero }
        let height = TooltipMetrics.keycapHeight * Self.scale
        return NSSize(width: keycap.width(forHeight: height), height: height)
    }

    /// The surface's size for the current text: as narrow as its one line, at most `maxWidth` wide (David Beyer,
    /// 2026-11-20: tooltips "look strangely wide"); past it the text ends in an ellipsis.
    func fittingSurfaceSize(maxWidth: CGFloat = TooltipMetrics.maxWidth * TooltipContentView.scale) -> NSSize {
        let scale = Self.scale
        let padBlock = TooltipMetrics.paddingBlock * scale
        let padInline = TooltipMetrics.paddingInline * scale
        let key = keycapSize
        // With a keycap, the end's room is the keycap's inset, and the gap sits between it and the text.
        let trailing = keycap == nil ? padInline : TooltipMetrics.keycapInset * scale + key.width + TooltipMetrics.keycapGap * scale
        // The label's natural frame holds its line padding each side of the glyphs; the surface counts the glyphs.
        let natural = text.naturalSize
        let glyphs = min(natural.width - LabelText.padding * 2, max(1, maxWidth - padInline - trailing))
        // One line is one height, keycap or not: the line height, or the keycap and its inset.
        let line = max(natural.height, TooltipMetrics.lineHeight * scale)
        let minHeight = keycap == nil ? 0 : key.height + TooltipMetrics.keycapInset * scale * 2
        return NSSize(width: ceil(padInline + glyphs + trailing), height: ceil(max(line + padBlock * 2, minHeight)))
    }

    override func layout() {
        super.layout()
        let scale = Self.scale
        let padInline = TooltipMetrics.paddingInline * scale
        let key = keycapSize
        let trailing = keycap == nil ? padInline : TooltipMetrics.keycapInset * scale + key.width + TooltipMetrics.keycapGap * scale
        // The label's frame: its line plus its own line padding (LabelText.padding) each side of the glyphs, cut to
        // the room before the keycap (its text then ends in an ellipsis).
        let natural = text.naturalSize
        let textSize = NSSize(width: min(natural.width, max(1, bounds.width - padInline - trailing) + LabelText.padding * 2),
                              height: natural.height)
        // The text sits in the middle of the surface, centred on the keycap.
        let middleY = (bounds.height - textSize.height) / 2
        let textY = middleY.rounded()
        // The frame starts the label's padding early, so its glyphs (not its frame) start at the inline padding
        // and end where fittingSurfaceSize measured them, the keycap gap before the keycap. The width is not rounded
        // up: the origin is whole, so the glyphs stay sharp, and a rounded width would reach past the gap.
        text.frame = NSRect(x: padInline - LabelText.padding, y: textY, width: textSize.width, height: ceil(textSize.height))
        if let keycap {
            // Centred on the line, as a menu's shortcut is: the label's own line height (the font's, in whole points),
            // not the nominal ``TooltipMetrics/lineHeight``, from the text's unrounded place, so an odd line (15 pt
            // at 12 pt) does not round the text and then the keycap down a point each.
            let y = max(TooltipMetrics.keycapInset * scale, (middleY + (textSize.height - key.height) / 2).rounded())
            keycap.frame = NSRect(x: bounds.width - TooltipMetrics.keycapInset * scale - key.width, y: y,
                                  width: key.width, height: key.height)
        }
    }
}
