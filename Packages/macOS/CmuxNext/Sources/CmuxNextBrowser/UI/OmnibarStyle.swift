import AppKit
import CmuxNextDesign

/// Omnibar and toolbar geometry and colors, taken from Helium
/// (imputnet/helium `patches/helium/ui/layout-constants.patch`,
/// `location-bar.patch`, `omnibox.patch`, `toolbar.patch`,
/// `helium-color-mixers.patch`; Chromium 154). Comfortable density uses
/// Helium's numbers; compact scales the heights down by 4 pt so the toolbar
/// stays close to a pane tab strip.
///
/// One deliberate difference: Helium draws its focus ring, text selection,
/// and keyword text in its blue primary color. cmux chrome has no blue
/// accents, so those use neutral grays.
enum OmnibarStyle {
    private static var compact: Bool { Metrics.density == .compact }

    /// Helium `kHeliumBasePadding`: most spacing is a multiple of it.
    static let basePadding: CGFloat = 3

    // MARK: Toolbar

    /// Omnibox and toolbar button height (Helium `LOCATION_BAR_HEIGHT` 28).
    static var barHeight: CGFloat { compact ? 24 : 28 }
    /// Toolbar row: the bar plus Helium's 3 pt vertical interior margin.
    static var toolbarHeight: CGFloat { barHeight + 2 * basePadding }
    /// Helium's 6 pt horizontal interior margin.
    static var toolbarInset: CGFloat { 2 * basePadding }
    /// Toolbar buttons: square, bar height, 8 pt hover shape.
    static var buttonSize: CGFloat { barHeight }
    static let buttonCornerRadius: CGFloat = 8
    static var buttonSymbolSize: CGFloat { compact ? 13 : 15 }
    static let buttonSpacing: CGFloat = 0
    /// Gap between the reload button and the omnibox, and the omnibox and
    /// the extension slot (Helium omnibox side margin).
    static var barMargin: CGFloat { 2 * basePadding }

    // MARK: Omnibox

    /// Helium `Emphasis::kHigh`.
    static let barCornerRadius: CGFloat = 8
    /// Page-info chip (Helium `kLocationBarChildCornerRadius` 6).
    static var chipSize: CGFloat { barHeight - 4 }
    static let chipCornerRadius: CGFloat = 6
    /// Chip distance from the bar's leading edge (Helium: 2).
    static let chipLeading: CGFloat = 2
    /// Text distance after the chip (Helium: 5).
    static let textLeading: CGFloat = 5
    static let trailingPadding: CGFloat = 8
    static var iconPointSize: CGFloat { compact ? 12 : 13 }
    /// Helium asks for 14 pt regular system text.
    static var font: NSFont { .systemFont(ofSize: compact ? 13 : 14, weight: .regular) }
    static var ringWidth: CGFloat { 1.5 }

    // MARK: Popup

    /// The popup card: radius 12, reaching 3 pt above the bar and 6 pt past
    /// each side so the bar sits inside it (Helium: 3 and 7; 6 keeps the
    /// card off the reload button with cmux's 6 pt gap).
    static let cardCornerRadius: CGFloat = 12
    static let cardTopOutset: CGFloat = basePadding
    static let cardSideOutset: CGFloat = 2 * basePadding
    /// Rows: bar height, inset 4 at the sides, 2 between rows, 4 at the end.
    static var rowHeight: CGFloat { barHeight }
    static let rowSideInset: CGFloat = 4
    static let rowGap: CGFloat = 2
    static let cardBottomPadding: CGFloat = 4
    static let rowCornerRadius: CGFloat = 8
    static var rowDetailFont: NSFont { font }

    // MARK: Colors

    /// Helium toolbar: white in light, `#1F1F1F` in dark.
    static let toolbarBackground = dynamic(light: 1.0, dark: 0.122)
    /// Idle bar fill: Neutral92 `#E8E8E8`; dark measured `#3C3C3C`.
    static let barFill = dynamic(light: 0.910, dark: 0.235)
    /// Hover: idle plus black 6% (light) or white 16% (dark).
    static let barHoverFill = dynamic(light: 0.855, dark: 0.357)
    /// Editing fill and popup card: white, dark `#3A3C3C`.
    static let cardFill = dynamic(light: 1.0, dark: 0.231)
    /// Neutral ring while editing with the popup closed (Helium: blue).
    static let ring = dynamic(light: 0.0, dark: 1.0, alpha: 0.22)
    /// Selected and hovered rows: black 6% / white 10%.
    static let rowSelectedFill = dynamic(light: 0.0, dark: 1.0, alpha: 0.06, darkAlpha: 0.10)
    /// Chip hover.
    static let chipHoverFill = dynamic(light: 0.0, dark: 1.0, alpha: 0.06, darkAlpha: 0.10)
    /// Text selection inside the field (Helium: blue tint).
    static let selection = dynamic(light: 0.0, dark: 1.0, alpha: 0.16, darkAlpha: 0.26)
    static var textPrimary: NSColor { Palette.textPrimary }
    static var textSecondary: NSColor { Palette.textSecondary }

    private static func dynamic(light: CGFloat, dark: CGFloat, alpha: CGFloat = 1, darkAlpha: CGFloat? = nil) -> NSColor {
        NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(white: isDark ? dark : light, alpha: isDark ? (darkAlpha ?? alpha) : alpha)
        }
    }
}
