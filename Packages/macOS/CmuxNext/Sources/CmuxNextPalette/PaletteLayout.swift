import AppKit
import CmuxNextDesign

/// Palette geometry derived from the shared Design tokens. Every value is
/// computed on read, so it follows `DesignSettings.shared` (density and
/// per-metric overrides) live; nothing here is a hardcoded size.
enum PaletteLayout {
    /// Result rows visible without scrolling. A count, not a size.
    static let visibleRows: CGFloat = 10

    static var width: CGFloat { Metrics.paletteWidth }
    static var searchHeight: CGFloat { Metrics.paletteSearchHeight + textGrowth(Typography.search) }
    static var rowHeight: CGFloat { Metrics.paletteRowHeight + textGrowth(Typography.body) }
    static var headerRowHeight: CGFloat { Metrics.sidebarHeaderHeight + textGrowth(Typography.header) }
    static var footerHeight: CGFloat { rowHeight }
    static var listInset: CGFloat { Metrics.space2 }
    static var listHeight: CGFloat { rowHeight * visibleRows + listInset * 2 }
    static var cornerRadius: CGFloat { Metrics.panelCornerRadius }
    static var rowCornerRadius: CGFloat { Metrics.itemCornerRadius }
    static var height: CGFloat { searchHeight + listHeight + footerHeight + 2 * Metrics.dividerThickness }
    static var horizontalPadding: CGFloat { Metrics.space5 }

    /// Transparent margin around the panel so the shadow and the open
    /// animation are never clipped by the window.
    static var shadowMargin: CGFloat { Metrics.space6 * 2 }

    static var windowSize: CGSize {
        CGSize(width: width + 2 * shadowMargin, height: height + 2 * shadowMargin)
    }

    static var actionsMenuWidth: CGFloat { width / 2 - Metrics.space6 }
    static var actionsMenuRowHeight: CGFloat { rowHeight - Metrics.space2 }
    static var keycapSize: CGFloat { Metrics.iconSize + Metrics.space2 + textGrowth(Typography.shortcut) }
    static var keycapCornerRadius: CGFloat { Metrics.itemCornerRadius - Metrics.space1 }
    static var iconBox: CGFloat { Metrics.iconSize + Metrics.space2 }

    /// How much larger the palette's text draws than the size its density's heights are made for:
    /// Interface Size (`appearance.metrics.chromeFontSize`) or a density's own `fontSize` grow the
    /// text but not `Metrics` heights, and 16 pt text in a 28 pt Compact row clipped (#26606).
    /// Never below 1, so smaller text keeps the density's heights.
    static var textScale: CGFloat {
        max(1, Typography.body.pointSize / Metrics.scale(Metrics.tokens.levelBodySize))
    }

    /// The extra line height of `font` over the same face at the density's own text size, on
    /// whole points: a row keeps its density's padding and grows only by the taller line, so a
    /// roomy row (or a height the person set) is not inflated in proportion. A face's line height
    /// scales with its point size, so the smaller face is arithmetic, not a font made per row: a
    /// font made and dropped like that can come back nil (`CheckedFont`, #20557), which would
    /// silently zero the growth.
    static func textGrowth(_ font: NSFont) -> CGFloat {
        let scale = textScale
        guard scale > 1 else { return 0 }
        return max(0, ceil(lineHeight(font) * (1 - 1 / scale)))
    }

    private static func lineHeight(_ font: NSFont) -> CGFloat {
        font.ascender - font.descender + font.leading
    }

    /// Every text size the palette draws in; a change in any of them restyles its labels.
    static var textSizes: [CGFloat] {
        [Typography.body, Typography.bodyEmphasized, Typography.caption, Typography.header, Typography.search, Typography.shortcut]
            .map(\.pointSize)
    }
}

extension NSView {
    /// `rect` on whole backing pixels, for a text field's frame set from `layout()` (cx-wcej; see
    /// `PaletteText.height`).
    func pixelAligned(_ rect: NSRect) -> NSRect {
        backingAlignedRect(rect, options: [.alignMinXNearest, .alignMinYNearest, .alignWidthNearest, .alignHeightNearest])
    }
}

/// Label helpers so every text view uses Design typography.
enum PaletteText {
    /// `font` is read again on `PaletteLabel.refreshFont()`, so a label follows a text size or
    /// density change made while the palette exists.
    static func label(_ font: @autoclosure @escaping @MainActor () -> NSFont, tone: PaletteTone? = .primary) -> PaletteLabel {
        let field = PaletteLabel(labelWithString: "")
        field.fontSource = font
        field.font = font()
        field.tone = tone
        field.lineBreakMode = .byTruncatingTail
        field.maximumNumberOfLines = 1
        field.cell?.truncatesLastVisibleLine = true
        return field
    }

    /// A text field's height for a frame set from `layout()`: its cell's height without bounds,
    /// up to whole backing pixels. Not `intrinsicContentSize`, which for a truncating label
    /// depends on the field's current frame: at some scales a row set 14 points, read back 13,
    /// set 13, read 14, and each change asked for another pass until AppKit threw "more Layout
    /// Window passes than there are views in the window" (cx-wcej).
    static func height(_ field: NSTextField) -> CGFloat {
        let unbounded = NSRect(x: 0, y: 0, width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        let natural = field.cell?.cellSize(forBounds: unbounded).height ?? field.intrinsicContentSize.height
        let scale = field.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        return ceil(natural * scale) / scale
    }

    /// Width that shows the whole string. `intrinsicContentSize` of a
    /// truncating label is unreliable after its value changes. At least the cell's own width
    /// without bounds, which adds its text padding: `space2` alone is less than that padding at
    /// Ultra-compact, and "Search", "Open" and "Actions" truncated there (#26606).
    static func fittingWidth(_ field: NSTextField) -> CGFloat {
        let unbounded = NSRect(x: 0, y: 0, width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        let cell = ceil(field.cell?.cellSize(forBounds: unbounded).width ?? 0)
        return max(cell, ceil(field.attributedStringValue.size().width) + Metrics.space2)
    }

    /// Configured SF Symbol images, made once per name and size: rows are
    /// reconfigured on every open and scroll, and each lookup plus
    /// configuration costs a millisecond or more in the symbol catalog.
    /// Tinting is per image view (`contentTintColor`), so one image serves
    /// every row. Bounded by the catalog's symbol names.
    private static var symbols: [SymbolKey: NSImage] = [:]
    private struct SymbolKey: Hashable {
        let name: String
        let size: CGFloat
    }

    static func symbol(_ name: String, size: CGFloat) -> NSImage? {
        let key = SymbolKey(name: name, size: size)
        if let cached = symbols[key] { return cached }
        let configuration = NSImage.SymbolConfiguration(pointSize: size, weight: .regular)
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(configuration) else {
            return nil
        }
        if symbols.count >= 1_024 { symbols.removeAll() }
        symbols[key] = image
        return image
    }
}
