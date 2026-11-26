import AppKit
import CmuxNextDesign
import CmuxNextIcons

/// Page Info geometry and colors. Sizes come from `Metrics`/`Typography`;
/// colors from `Palette` (Ghostty-derived). cmux has no accent color, so
/// "on" toggles and links use the foreground.
enum PageInfoStyle {
    /// The page info bubble is at least 320 points wide.
    static var bubbleWidth: CGFloat { Metrics.density == .compact ? 320 : 344 }
    /// The redraw's numbers when a look other than today's is on (``PageInfoLook``); nil today.
    static var look: PageInfoLookGeometry? { PageInfoLook.active.geometry }
    static var rowHeight: CGFloat { look?.rowHeight ?? Metrics.paletteRowHeight }
    static var rowHeightWithSubtitle: CGFloat { look?.rowHeightWithSubtitle ?? Metrics.sidebarRowHeightWithSubtitle + Metrics.panelInset }
    /// Twice the space between the bubble's edge and its page.
    static var inset: CGFloat { look.map { $0.cardPadding * 2 } ?? Metrics.panelInset * 2 }
    static var rowInset: CGFloat { Metrics.panelInset }
    static var iconSize: CGFloat { Metrics.iconSize }
    static var iconColumn: CGFloat { Metrics.iconSize + Metrics.panelInset * 2 }
    static var cornerRadius: CGFloat { look?.cornerRadius ?? PopupStyle.standard.cornerRadius }
    static var buttonCornerRadius: CGFloat { Metrics.buttonCornerRadius }
    static var spacing: CGFloat { Metrics.panelInset }
    static var toggleSize: CGSize { Metrics.density == .compact ? CGSize(width: 28, height: 16) : CGSize(width: 32, height: 18) }

    static var titleFont: NSFont { look.map { font($0.headerFont) } ?? Typography.bodyEmphasized }
    /// A row's title.
    static var rowFont: NSFont { look.map { font($0.font) } ?? Typography.body }
    /// The header title's ink: a section header's secondary ink in the menu and band looks.
    static var headerText: NSColor { look?.headerFont == .sectionHeader ? secondaryText : text }

    static func font(_ font: PageInfoLookGeometry.Font) -> NSFont {
        switch font {
        case .body: Typography.body
        case .card: Typography.cardBody
        case .sectionHeader: Typography.header
        case .cardTitle: Typography.cardTitle
        }
    }
    static var captionFont: NSFont { Typography.caption }

    static var background: NSColor { Palette.elevatedBackground } // theme-scoped
    static var text: NSColor { Palette.textPrimary } // theme-scoped
    static var secondaryText: NSColor { Palette.textSecondary } // theme-scoped
    static var hover: NSColor { Palette.hoverFill } // theme-scoped
    static var pressed: NSColor { Palette.pressedFill } // theme-scoped
    static var focusRing: NSColor { Palette.focusRing } // theme-scoped
    static var danger: NSColor { Palette.danger } // theme-scoped

    /// The pack icon for SF Symbol `name` (else the symbol) beside a `size`-point label.
    static func symbol(_ name: String, size: CGFloat? = nil) -> NSImage? {
        NSImage.icon(symbol: name, size: .iconRowSize(forLabelPointSize: size ?? iconSize))
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
