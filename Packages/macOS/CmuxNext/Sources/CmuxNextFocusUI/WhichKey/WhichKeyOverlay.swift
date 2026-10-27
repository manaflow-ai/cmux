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
            Motion.overlays.animateTimed(.fadeIn, in: glass) { glass.animator().alphaValue = 1 }
        }
    }

    func dismiss() {
        guard let handle, !handle.isDismissed, !isDismissing else { return }
        isDismissing = true
        Motion.overlays.animateTimed(.fadeOut, in: glass, { glass.animator().alphaValue = 0 }, completion: { [weak self] in
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

/// The overlay's body, as layers (no backing store): the leader's keycaps and
/// the cancel hint on top, then one row per key (monospace keycap, action
/// title) in as many columns as fit. A cap is a layer fill with a
/// ``ChromeTextLayer`` glyph; a title or the hint is a ``ChromeTextLayer``.
/// Theme tokens only, read inside `performWithTheme`.
final class WhichKeyView: NSView {
    private var prefixCaps: [String] = []
    private var rows: [WhichKeyRow] = []
    private var columns = 1 {
        didSet { if columns != oldValue { needsDisplay = true } }
    }
    /// One keycap: its fill and its glyphs.
    private struct Cap {
        let fill: ChromeFillLayer
        let text: ChromeTextLayer
    }
    private var prefixLayers: [Cap] = []
    private var rowLayers: [(cap: Cap, title: ChromeTextLayer)] = []
    private let hintLayer = ChromeTextLayer()
    private var keyColumnWidth: CGFloat = 0
    private var columnWidth: CGFloat = 0
    /// Longest a title draws before it truncates.
    private static let maxTitleWidth: CGFloat = 280

    nonisolated override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        hintLayer.actions = Self.still
        hintLayer.font = Typography.caption
        hintLayer.string = WhichKeyStrings.cancelHint
        layer?.addSublayer(hintLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func update(prefix: [String], rows newRows: [WhichKeyRow]) {
        prefixCaps = prefix
        rows = newRows
        prefixLayers.forEach { $0.fill.removeFromSuperlayer() }
        rowLayers.forEach { $0.cap.fill.removeFromSuperlayer(); $0.title.removeFromSuperlayer() }
        prefixLayers = prefix.map(makeCap)
        rowLayers = rows.map { row in
            let title = Self.textLayer(row.title, font: Typography.body)
            title.truncation = .end
            layer?.addSublayer(title)
            return (cap: makeCap(row.key), title: title)
        }
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

    nonisolated override var wantsUpdateLayer: Bool { true }

    /// Places and colors the layers: the caps and hint on top, then the rows by column.
    override func updateLayer() {
        let scale = window?.backingScaleFactor ?? 2
        let (fill, primary, dimmed) = performWithTheme {
            (Palette.hoverFill.cgColor, Palette.textPrimary.cgColor, Palette.textTertiary.cgColor)
        }
        var x = inset
        for (cap, layers) in zip(prefixCaps, prefixLayers) {
            x += place(layers, cap, at: NSPoint(x: x, y: inset), fill: fill, ink: primary, scale: scale) + Metrics.space1
        }
        let hintWidth = width(WhichKeyStrings.cancelHint, Typography.caption)
        place(hintLayer, in: NSRect(x: bounds.maxX - inset - hintWidth, y: inset, width: hintWidth, height: lineHeight),
              ink: dimmed, scale: scale)
        let top = inset + lineHeight + Metrics.space3
        for (index, (row, layers)) in zip(rows, rowLayers).enumerated() {
            let column = CGFloat(index / rowsPerColumn), line = CGFloat(index % rowsPerColumn)
            let origin = NSPoint(x: inset + column * (columnWidth + columnGap), y: top + line * (lineHeight + Metrics.space1))
            let ink = row.isEnabled ? primary : dimmed
            place(layers.cap, row.key, at: origin, fill: fill, ink: ink, scale: scale)
            let titleX = origin.x + keyColumnWidth + Metrics.space2
            place(layers.title, in: NSRect(x: titleX, y: origin.y, width: max(0, min(columnWidth - keyColumnWidth - Metrics.space2,
                                                                                      bounds.maxX - inset - titleX)), height: lineHeight),
                  ink: ink, scale: scale)
        }
    }

    override func setFrameSize(_ newSize: NSSize) {
        let oldSize = frame.size
        super.setFrameSize(newSize)
        if newSize != oldSize { needsDisplay = true } // invalidate: the hint and the titles' widths follow the width
    }

    private func makeCap(_ cap: String) -> Cap {
        let fill = ChromeFillLayer()
        fill.cornerRadius = Metrics.itemCornerRadius
        let text = Self.textLayer(cap, font: Typography.shortcut)
        text.alignmentMode = .center
        fill.addSublayer(text)
        layer?.addSublayer(fill)
        return Cap(fill: fill, text: text)
    }

    private static func textLayer(_ string: String, font: NSFont) -> ChromeTextLayer {
        let text = ChromeTextLayer()
        text.actions = still
        text.font = font
        text.string = string
        return text
    }

    /// The glyph layers' own keys that the body changes: all still.
    private static let still: [String: any CAAction] = [
        "bounds": NSNull(), "position": NSNull(), "frame": NSNull(), "contents": NSNull(), "contentsScale": NSNull(),
        "hidden": NSNull(), "onOrderIn": NSNull(), "onOrderOut": NSNull(),
    ]

    /// One rounded keycap at the top left of a line, in colors `updateLayer`
    /// read in the theme scope; returns its width.
    @discardableResult
    private func place(_ layers: Cap, _ cap: String, at origin: NSPoint, fill: CGColor, ink: CGColor, scale: CGFloat) -> CGFloat {
        let size = NSSize(width: capWidth(cap), height: capHeight)
        layers.fill.frame = NSRect(origin: NSPoint(x: origin.x, y: origin.y + (lineHeight - size.height) / 2), size: size)
        layers.fill.backgroundColor = fill
        place(layers.text, in: NSRect(origin: .zero, size: size), ink: ink, scale: scale)
        return size.width
    }

    /// One line of text, vertically centered in `rect`, truncated at its end when it truncates.
    private func place(_ text: ChromeTextLayer, in rect: NSRect, ink: CGColor, scale: CGFloat) {
        let height = ceil(text.font.ascender - text.font.descender)
        text.frame = NSRect(x: rect.minX, y: rect.midY - height / 2, width: rect.width, height: height)
        text.foregroundColor = ink
        text.contentsScale = scale
    }
}
