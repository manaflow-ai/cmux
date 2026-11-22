import AppKit
import CmuxNextDesign

/// Page Info geometry and colors. Sizes come from `Metrics`/`Typography`;
/// colors from `Palette` (Ghostty-derived). cmux has no accent color, so
/// "on" toggles and links use the foreground.
enum PageInfoStyle {
    /// The page info bubble is at least 320 points wide.
    static var bubbleWidth: CGFloat { Metrics.density == .compact ? 320 : 344 }
    static var rowHeight: CGFloat { Metrics.paletteRowHeight }
    static var rowHeightWithSubtitle: CGFloat { Metrics.sidebarRowHeightWithSubtitle + Metrics.panelInset }
    static var inset: CGFloat { Metrics.panelInset * 2 }
    static var rowInset: CGFloat { Metrics.panelInset }
    static var iconSize: CGFloat { Metrics.iconSize }
    static var iconColumn: CGFloat { Metrics.iconSize + Metrics.panelInset * 2 }
    static var cornerRadius: CGFloat { Metrics.panelCornerRadius }
    static var itemCornerRadius: CGFloat { Metrics.itemCornerRadius }
    static var spacing: CGFloat { Metrics.panelInset }
    static var shadowMargin: CGFloat { Metrics.panelInset * 3 }
    static var toggleSize: CGSize { Metrics.density == .compact ? CGSize(width: 28, height: 16) : CGSize(width: 32, height: 18) }

    static var titleFont: NSFont { Typography.bodyEmphasized }
    static var bodyFont: NSFont { Typography.body }
    static var captionFont: NSFont { Typography.caption }
    static var headerFont: NSFont { Typography.header }

    static var background: NSColor { Palette.elevatedBackground } // theme-scoped
    static var text: NSColor { Palette.textPrimary } // theme-scoped
    static var secondaryText: NSColor { Palette.textSecondary } // theme-scoped
    static var tertiaryText: NSColor { Palette.textTertiary } // theme-scoped
    static var hover: NSColor { Palette.hoverFill } // theme-scoped
    static var pressed: NSColor { Palette.pressedFill } // theme-scoped
    static var separator: NSColor { Palette.separator } // theme-scoped
    static var focusRing: NSColor { Palette.focusRing } // theme-scoped
    static var danger: NSColor { Palette.danger } // theme-scoped

    static func symbol(_ name: String, size: CGFloat? = nil, weight: NSFont.Weight = .regular) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: size ?? iconSize, weight: weight))
    }

    /// A label whose `color` is read inside its theme scope on every theme
    /// change (`ThemedLabel`), so pass a style color, not a resolved one.
    static func label(_ text: String = "", font: NSFont, color: @escaping @autoclosure () -> NSColor, wraps: Bool = false) -> NSTextField {
        let label = wraps ? ThemedLabel(wrappingLabelWithString: text) : ThemedLabel(labelWithString: text)
        label.font = font
        label.themeColor = color
        label.translatesAutoresizingMaskIntoConstraints = false
        if !wraps { label.lineBreakMode = .byTruncatingTail }
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return label
    }
}
