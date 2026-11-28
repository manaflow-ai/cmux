import AppKit
import CmuxNextDesign
import CmuxNextIcons

/// Page Info geometry and colors: the agent pane's menu tokens (dp-738189f94e). Rows sit on the
/// menu grid (``MenuMetrics``: highlight 5 in from the popup edge, icon at 15 in a 14 box, label
/// after it, ``GlassMenuMaterial/rowHeight`` rows), type from `Typography`, colors from `Palette`.
/// cmux has no accent color, so "on" toggles and links use the foreground ink; the one saturated
/// hue stays reserved for driver state.
enum PageInfoStyle {
    /// The page info bubble is at least 320 points wide.
    static var bubbleWidth: CGFloat { Metrics.density == .compact ? 320 : 344 }
    /// A one-line row: the menu row (28) at every density.
    static var rowHeight: CGFloat { GlassMenuMaterial.rowHeight }
    static var rowHeightWithSubtitle: CGFloat { Metrics.sidebarRowHeightWithSubtitle + Metrics.panelInset }
    /// The card's inset around its rows, both sides together: the menu highlight inset on each.
    static var inset: CGFloat { MenuMetrics.highlightInset * 2 }
    /// From a row's leading edge to its icon (or a header's title): the menu's 15 from the popup edge.
    static var rowInset: CGFloat { MenuMetrics.iconX - MenuMetrics.highlightInset }
    /// From a row's trailing edge to its chevron or switch: the menu's 12 from the popup edge.
    static var trailingInset: CGFloat { MenuMetrics.trailing - MenuMetrics.highlightInset }
    /// From a row's leading edge to its text column (icon column + gap), for notes under a row.
    static var textLeading: CGFloat { MenuMetrics.textX(iconColumn: true) - MenuMetrics.highlightInset }
    static var iconSize: CGFloat { MenuMetrics.iconSize }
    static var iconGap: CGFloat { MenuMetrics.iconGap }
    /// How far left of the omnibar chip the bubble opens (its anchor, unchanged by the menu grid).
    static var anchorInset: CGFloat { Metrics.panelInset }
    static var cornerRadius: CGFloat { GlassMenuMaterial.cornerRadius }
    static var buttonCornerRadius: CGFloat { MenuMetrics.highlightRadius } // radius-allow: page info rows are menu rows; their highlight takes the menu grid's radius
    static var spacing: CGFloat { MenuMetrics.iconGap }
    /// A switch that fits a 28 row at every density (the agent pane's small switch).
    static var toggleSize: CGSize { CGSize(width: 32, height: 18) }

    static var titleFont: NSFont { Typography.bodyEmphasized }
    static var captionFont: NSFont { Typography.caption }

    static var background: NSColor { Palette.elevatedBackground } // theme-scoped
    static var text: NSColor { Palette.textPrimary } // theme-scoped
    static var secondaryText: NSColor { Palette.textSecondary } // theme-scoped
    static var hover: NSColor { Palette.hoverFill } // theme-scoped
    static var pressed: NSColor { Palette.pressedFill } // theme-scoped
    static var focusRing: NSColor { Palette.focusRing } // theme-scoped
    static var danger: NSColor { Palette.danger } // theme-scoped

    /// The pack icon for SF Symbol `name` (else the symbol), `size` points square (the menu icon box by default).
    static func symbol(_ name: String, size: CGFloat? = nil) -> NSImage? {
        NSImage.icon(symbol: name, size: size ?? iconSize)
    }

    /// A label whose `color` is read inside its theme scope on every theme
    /// change (`ThemedLabel`), so pass a style color, not a resolved one.
    static func label(_ text: String = "", font: NSFont, color: @escaping @autoclosure () -> NSColor, wraps: Bool = false) -> ThemedLabel {
        let label = wraps ? ThemedLabel(wrappingLabelWithString: text) : ThemedLabel(labelWithString: text)
        label.font = font
        label.themeColor = color
        label.translatesAutoresizingMaskIntoConstraints = false
        if !wraps { label.lineBreakMode = .byTruncatingTail }
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return label
    }
}
