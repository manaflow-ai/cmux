import AppKit
import CmuxNextDesign

/// Page Info geometry and colors. Sizes come from `Metrics`/`Typography`;
/// colors from `Palette` (Ghostty-derived). Chrome draws toggles and links
/// in its blue accent; cmux has none, so "on" and links use the foreground.
enum PageInfoStyle {
    /// Chrome's page info bubble is 320 dp minimum.
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

    static var background: NSColor { Palette.elevatedBackground }
    static var text: NSColor { Palette.textPrimary }
    static var secondaryText: NSColor { Palette.textSecondary }
    static var tertiaryText: NSColor { Palette.textTertiary }
    static var hover: NSColor { Palette.hoverFill }
    static var pressed: NSColor { Palette.pressedFill }
    static var separator: NSColor { Palette.separator }
    static var focusRing: NSColor { Palette.focusRing }
    static var danger: NSColor { Palette.danger }

    static func symbol(_ name: String, size: CGFloat? = nil, weight: NSFont.Weight = .regular) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: size ?? iconSize, weight: weight))
    }

    static func label(_ text: String = "", font: NSFont, color: NSColor, wraps: Bool = false) -> NSTextField {
        let label = wraps ? NSTextField(wrappingLabelWithString: text) : NSTextField(labelWithString: text)
        label.font = font
        label.textColor = color
        label.translatesAutoresizingMaskIntoConstraints = false
        if !wraps { label.lineBreakMode = .byTruncatingTail }
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return label
    }
}
