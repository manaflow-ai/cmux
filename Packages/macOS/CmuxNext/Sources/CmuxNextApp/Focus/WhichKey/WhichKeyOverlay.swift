import AppKit
import CmuxNextActions
import CmuxNextDesign

/// The which-key overlay: a click-through glass card (opaque under Reduce
/// Transparency, `Glass.makeOverlayPanel`) at the bottom center of the
/// shell window, presented on the window's overlay host so it stays above
/// Chromium page windows. It never takes the keyboard or the mouse: the key
/// router keeps the leader's second key. Fades follow `Motion` (shortened
/// under Reduce Motion, none at animation speed off).
final class WhichKeyOverlay {
    static let accessibilityID = "app.whichKey"
    /// Widest the overlay grows on a wide window; more rows add columns
    /// up to it, then grow each column.
    static let maxWidth: CGFloat = 960

    private let glass: OverlaySurfaceView
    private let body = WhichKeyView()
    private weak var parentWindowRef: NSWindow?
    private var handle: OverlayHandle?
    private var isDismissing = false

    init() {
        glass = Glass.makeOverlayPanel(cornerRadius: Metrics.panelCornerRadius, interactive: false)
        glass.translatesAutoresizingMaskIntoConstraints = true
        body.frame = glass.contentView.bounds
        body.autoresizingMask = [.width, .height]
        glass.contentView.addSubview(body)
        glass.setAccessibilityIdentifier(Self.accessibilityID)
    }

    /// Shows `rows` under `prefix` over `parent`, fading in unless shown.
    func present(prefix: [String], rows: [WhichKeyRow], on parent: NSWindow) {
        let wasDismissing = isDismissing
        isDismissing = false
        body.update(prefix: prefix, rows: rows)
        if parentWindowRef !== parent {
            handle?.dismiss()
            handle = nil
            parentWindowRef = parent
            // The overlay follows its window's theme changes.
            parent.themeScope.addResponder(self)
        }
        themeDidChange()
        let size = body.size(fitting: min(Self.maxWidth, parent.frame.width - Metrics.space6 * 2))
        glass.setFrameSize(size)
        // Bottom center of the window (a toast sits 24 pt above its anchor's bottom edge).
        let bottom = NSRect(x: 0, y: Metrics.space6 - 24, width: parent.frame.width, height: size.height)
        if let handle, !handle.isDismissed {
            handle.update(anchor: bottom)
        } else {
            glass.alphaValue = 0
            handle = WindowOverlayHost.host(for: parent).present(glass, options: OverlayOptions(kind: .toast, anchor: bottom, passesThroughClicks: true))
        }
        if glass.alphaValue < 1 || wasDismissing {
            Motion.animateTimed(.fadeIn) { glass.animator().alphaValue = 1 }
        }
    }

    func dismiss() {
        guard let handle, !handle.isDismissed, !isDismissing else { return }
        isDismissing = true
        Motion.animateTimed(.fadeOut, { glass.animator().alphaValue = 0 }, completion: { [weak self] in
            guard let self, self.isDismissing else { return }
            self.isDismissing = false
            self.handle?.dismiss()
            self.handle = nil
        })
    }
}

extension WhichKeyOverlay: ThemeResponsive {
    func themeDidChange() {
        glass.applyTheme()
        body.needsDisplay = true
    }
}

/// The overlay's body, drawn directly: the leader's keycaps and the cancel
/// hint on top, then one row per key (monospace keycap, action title) in
/// as many columns as fit. Theme tokens only, read inside `performWithTheme`.
final class WhichKeyView: NSView {
    private var prefixCaps: [String] = []
    private var rows: [WhichKeyRow] = []
    private var columns = 1
    private var keyColumnWidth: CGFloat = 0
    private var columnWidth: CGFloat = 0
    /// Longest a title draws before it truncates.
    private static let maxTitleWidth: CGFloat = 280

    override var isFlipped: Bool { true }

    func update(prefix: [String], rows newRows: [WhichKeyRow]) {
        prefixCaps = prefix
        rows = newRows
        keyColumnWidth = rows.map { capWidth($0.key) }.max() ?? capHeight
        let titleWidth = rows.map { min(width($0.title, Typography.body), Self.maxTitleWidth) }.max() ?? 0
        columnWidth = keyColumnWidth + Metrics.space2 + titleWidth
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel(WhichKeyStrings.accessibilityLabel)
        let listed = rows.map { "\($0.key): \($0.title)" }.joined(separator: ", ")
        setAccessibilityValue(listed)
        needsDisplay = true
    }

    private var inset: CGFloat { Metrics.space4 }
    private var columnGap: CGFloat { Metrics.space6 }
    private var capHeight: CGFloat {
        let font = Typography.shortcut
        return ceil(font.ascender - font.descender) + Metrics.space1 * 2
    }
    private var lineHeight: CGFloat { max(capHeight, ceil(Typography.body.ascender - Typography.body.descender)) }

    private func width(_ text: String, _ font: NSFont) -> CGFloat {
        ceil((text as NSString).size(withAttributes: [.font: font]).width)
    }

    private func capWidth(_ cap: String) -> CGFloat {
        max(capHeight, width(cap, Typography.shortcut) + Metrics.space2 * 2)
    }

    private var rowsPerColumn: Int { max(1, (rows.count + columns - 1) / columns) }

    /// The size at most `maxWidth` wide; sets the column count it draws with.
    func size(fitting maxWidth: CGFloat) -> NSSize {
        let fit = Int((max(maxWidth - inset * 2, columnWidth) + columnGap) / (columnWidth + columnGap))
        columns = max(1, min(rows.count, fit))
        let header = prefixCaps.map(capWidth).reduce(0) { $0 + $1 + Metrics.space1 } + Metrics.space6
            + width(WhichKeyStrings.cancelHint, Typography.caption)
        let content = CGFloat(columns) * columnWidth + CGFloat(columns - 1) * columnGap
        let lines = CGFloat(rowsPerColumn)
        let height = inset * 2 + lineHeight + Metrics.space3 + lines * lineHeight + (lines - 1) * Metrics.space1
        return NSSize(width: ceil(min(maxWidth, max(header, content) + inset * 2)), height: ceil(height))
    }

    override func draw(_ dirtyRect: NSRect) {
        performWithTheme {
            let fill = Palette.hoverFill, primary = Palette.textPrimary, dimmed = Palette.textTertiary
            var x = inset
            for cap in prefixCaps { x += drawCap(cap, at: NSPoint(x: x, y: inset), fill: fill, color: primary) + Metrics.space1 }
            let hint = WhichKeyStrings.cancelHint
            drawText(hint, font: Typography.caption, color: dimmed,
                     in: NSRect(x: bounds.maxX - inset - width(hint, Typography.caption), y: inset,
                                width: width(hint, Typography.caption), height: lineHeight))
            let top = inset + lineHeight + Metrics.space3
            for (index, row) in rows.enumerated() {
                let column = CGFloat(index / rowsPerColumn), line = CGFloat(index % rowsPerColumn)
                let origin = NSPoint(x: inset + column * (columnWidth + columnGap), y: top + line * (lineHeight + Metrics.space1))
                _ = drawCap(row.key, at: origin, fill: fill, color: row.isEnabled ? primary : dimmed)
                let titleX = origin.x + keyColumnWidth + Metrics.space2
                drawText(row.title, font: Typography.body, color: row.isEnabled ? primary : dimmed,
                         in: NSRect(x: titleX, y: origin.y, width: max(0, min(columnWidth - keyColumnWidth - Metrics.space2,
                                                                               bounds.maxX - inset - titleX)), height: lineHeight))
            }
        }
    }

    /// One rounded keycap at the top left of a line, in colors `draw`
    /// read in the theme scope; returns its width.
    private func drawCap(_ cap: String, at origin: NSPoint, fill: NSColor, color: NSColor) -> CGFloat {
        let size = NSSize(width: capWidth(cap), height: capHeight)
        let rect = NSRect(origin: NSPoint(x: origin.x, y: origin.y + (lineHeight - size.height) / 2), size: size)
        fill.setFill()
        NSBezierPath(roundedRect: rect, xRadius: Metrics.itemCornerRadius, yRadius: Metrics.itemCornerRadius).fill()
        let attributes: [NSAttributedString.Key: Any] = [.font: Typography.shortcut, .foregroundColor: color]
        let text = cap as NSString
        let textSize = text.size(withAttributes: attributes)
        text.draw(at: NSPoint(x: rect.midX - textSize.width / 2, y: rect.midY - textSize.height / 2), withAttributes: attributes)
        return size.width
    }

    /// One line of text, vertically centered in `rect`, truncated at its end.
    private func drawText(_ text: String, font: NSFont, color: NSColor, in rect: NSRect) {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .paragraphStyle: style]
        let height = ceil(font.ascender - font.descender)
        (text as NSString).draw(in: NSRect(x: rect.minX, y: rect.midY - height / 2, width: rect.width, height: height),
                                withAttributes: attributes)
    }
}
