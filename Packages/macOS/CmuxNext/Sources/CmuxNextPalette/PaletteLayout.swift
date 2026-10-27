import AppKit
import CmuxNextDesign

/// Palette geometry derived from the shared Design tokens. Every value is
/// computed on read, so it follows `DesignSettings.shared` (density and
/// per-metric overrides) live; nothing here is a hardcoded size.
enum PaletteLayout {
    /// Result rows visible without scrolling. A count, not a size.
    static let visibleRows: CGFloat = 10

    static var width: CGFloat { Metrics.paletteWidth }
    static var searchHeight: CGFloat { Metrics.paletteSearchHeight }
    static var rowHeight: CGFloat { Metrics.paletteRowHeight }
    static var headerRowHeight: CGFloat { Metrics.sidebarHeaderHeight }
    static var footerHeight: CGFloat { Metrics.paletteRowHeight }
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
    static var keycapSize: CGFloat { Metrics.iconSize + Metrics.space2 }
    static var keycapCornerRadius: CGFloat { Metrics.itemCornerRadius - Metrics.space1 }
    static var iconBox: CGFloat { Metrics.iconSize + Metrics.space2 }
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
    static func label(_ font: NSFont, tone: PaletteTone? = .primary) -> PaletteLabel {
        let field = PaletteLabel(labelWithString: "")
        field.font = font
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
    /// truncating label is unreliable after its value changes.
    static func fittingWidth(_ field: NSTextField) -> CGFloat {
        ceil(field.attributedStringValue.size().width) + Metrics.space2
    }

    // memory: fixed keys are SF Symbol names from the command catalog and scope chips times the two
    // Design icon sizes, cleared at 1,024; a symbol image holds vectors and one small drawn rep.
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
