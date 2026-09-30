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
    static var shadowRadius: CGFloat { Metrics.space6 + Metrics.space4 }
    static var shadowOffset: CGFloat { Metrics.space4 }

    static var windowSize: CGSize {
        CGSize(width: width + 2 * shadowMargin, height: height + 2 * shadowMargin)
    }

    static var actionsMenuWidth: CGFloat { width / 2 - Metrics.space6 }
    static var actionsMenuRowHeight: CGFloat { rowHeight - Metrics.space2 }
    static var keycapSize: CGFloat { Metrics.iconSize + Metrics.space2 }
    static var keycapCornerRadius: CGFloat { Metrics.itemCornerRadius - Metrics.space1 }
    static var iconBox: CGFloat { Metrics.iconSize + Metrics.space2 }
}

/// Label helpers so every text view uses Design typography.
enum PaletteText {
    static func label(_ font: NSFont, color: NSColor = Palette.textPrimary) -> NSTextField {
        let field = NSTextField(labelWithString: "")
        field.font = font
        field.textColor = color
        field.lineBreakMode = .byTruncatingTail
        field.maximumNumberOfLines = 1
        field.cell?.truncatesLastVisibleLine = true
        return field
    }

    /// Width that shows the whole string. `intrinsicContentSize` of a
    /// truncating label is unreliable after its value changes.
    static func fittingWidth(_ field: NSTextField) -> CGFloat {
        ceil(field.attributedStringValue.size().width) + Metrics.space2
    }

    static func symbol(_ name: String, size: CGFloat, color: NSColor = Palette.textSecondary) -> NSImage? {
        let configuration = NSImage.SymbolConfiguration(pointSize: size, weight: .regular)
        return NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(configuration)
    }
}
