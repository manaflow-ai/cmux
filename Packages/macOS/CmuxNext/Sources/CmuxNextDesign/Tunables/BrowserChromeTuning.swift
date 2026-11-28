public import CmuxNextDesignTokens
public import CoreGraphics

/// The browser pane's tab bar and omnibar numbers, per density, as Debug Settings tunables (Lawrence 2026-11-13,
/// density thread: Default matches Helium pixel for pixel, Compact is the same design on 20 pt rows, Spacious is
/// Helium's shapes at Chrome's sizes). The Density Overlay Playground and Debug Settings > Browser Chrome tune them
/// live; each override belongs to one density (`browserChrome.<density>.<metric>`), so tuning Default leaves
/// Compact as it was.
///
/// The defaults live here once: the tab strip (`TabTunables`, `TabStripMetrics`), the omnibar (`OmnibarStyle`) and
/// the rows (``Metrics/chromeRowHeight``, ``Metrics/browserRowGap``) read ``value(_:)`` or ``override(_:)``.
/// Only the built-in densities with browser rows are tunable; a custom density keeps the defaults.
///
/// ```swift
/// let square = BrowserChromeTuning.value(.closeSize) // 14 at Default, unless tuned
/// ```
public nonisolated struct BrowserChromeTuning {
    public nonisolated init() {}
    /// The Debug Settings section that lists the values.
    public static let section = TunableSection(id: "browserChrome", title: "Browser Chrome", symbol: "macwindow", order: 14)

    /// The densities with their own values, smallest first.
    public static let densities: [DensityPreset] = [.compact, .cozy, .comfortable, .spacious]

    /// The tunable key of `metric` at `density`.
    public static func key(_ metric: BrowserChromeMetric, density: DensityPreset) -> String {
        "browserChrome.\(density.rawValue).\(metric.rawValue)"
    }

    /// Every value of every density, by density then metric (Debug Settings and the playground list these).
    public static let all: [ComputedTunable] = densities.flatMap { density in
        BrowserChromeMetric.allCases.map { metric in
            ComputedTunable(key(metric, density: density), section, "\(density.tokens.name): \(metric.label)", help: metric.help,
                            range: metric.range, code: "BrowserChromeTuning.\(metric.rawValue)") {
                defaultValue(metric, tokens: density.tokens, row: nil)
            }
        }
    }

    /// The descriptors of ``all``.
    public static var descriptors: [TunableDescriptor] { all.map(\.descriptor) }

    /// The override of `metric` for the density `tokens` draws, if it is a tunable one and has one.
    public static func override(_ metric: BrowserChromeMetric, tokens: DensityTokens, store: TunableStore = .shared) -> CGFloat? {
        guard let density = DensityPreset(rawValue: tokens.id), densities.contains(density) else { return nil }
        return store.override(key(metric, density: density))?.number.map { CGFloat($0) }
    }

    /// The override of `metric` at the density chrome draws in now.
    @MainActor public static func override(_ metric: BrowserChromeMetric) -> CGFloat? {
        override(metric, tokens: Metrics.tokens)
    }

    /// `metric` at the density chrome draws in now: its override, else its default.
    @MainActor public static func value(_ metric: BrowserChromeMetric) -> CGFloat {
        override(metric) ?? defaultValue(metric)
    }

    /// `metric`'s default at the density chrome draws in now (no override), on the live row (Interface Size included).
    @MainActor static func defaultValue(_ metric: BrowserChromeMetric) -> CGFloat {
        defaultValue(metric, tokens: Metrics.tokens, row: Metrics.tabHeight)
    }

    /// `metric`'s default at `tokens`: Helium's share of `row` (the density's `browserRowHeight` when nil), or the
    /// density's own token for the row and the gap.
    static func defaultValue(_ metric: BrowserChromeMetric, tokens: DensityTokens, row: CGFloat?) -> CGFloat {
        let row = row ?? tokens.tokens["browserRowHeight"].map { CGFloat($0) } ?? 28
        let chromeColumn = (tokens.tokens["omnibarChromeColumn"] ?? 0) > 0
        // A density's own value (the Density Playground's tab close button tokens) wins over Helium's share.
        if let key = metric.densityKey, let exact = tokens.tokens[key] { return CGFloat(exact) }
        switch metric {
        case .rowHeight, .rowGap: return metric.token.flatMap { tokens.tokens[$0] }.map { CGFloat($0) } ?? 0
        // Helium's x in points, not a share of the row (Lawrence 2026-11-28: "size and icon size etc must perfectly match
        // helium"): its Default density's on a tab under 32 pt, its Spacious density's from 32 pt (``HeliumClose``).
        case .closeSize: return HeliumClose(row: row).slot
        case .closeCorner: return HeliumClose(row: row).corner
        case .closeInk: return HeliumClose(row: row).ink
        case .closeTrailing: return HeliumClose(row: row).trailing
        case .closeHoverOpacity: return 16 // tab_close_button.cc's highlight opacity, at every density
        // The omnibar's own tokens where the density sets them (its bar can differ from the tab row: 28 on 29 at Default).
        case .chipLeading:
            if let leading = tokens.tokens["omnibarIconLeading"] { return CGFloat(leading) }
            return chipLeading(bar: tokens.tokens["omnibarHeight"].map { CGFloat($0) } ?? row, chromeColumn: chromeColumn)
        case .textOrigin:
            if let leading = tokens.tokens["omnibarIconLeading"], let view = tokens.tokens["omnibarIconViewSize"], let gap = tokens.tokens["omnibarTextGap"] {
                let bar = tokens.tokens["omnibarHeight"] ?? Double(row)
                let edge = tokens.tokens["omnibarEdgeInset"] ?? 2
                return CGFloat(leading + min(view, bar - 2 * edge) + gap)
            }
            return textOrigin(bar: tokens.tokens["omnibarHeight"].map { CGFloat($0) } ?? row, chromeColumn: chromeColumn)
        }
    }

    /// Whether the density draws Chrome's omnibox column (Spacious's `omnibarChromeColumn` token) rather than Helium's.
    @MainActor public static var usesChromeColumn: Bool { (Metrics.tokens.tokens["omnibarChromeColumn"] ?? 0) > 0 }

    /// The page-info chip's inset in a `bar` tall omnibar: Helium's 2 of 28 (location-bar.patch's edge padding), or
    /// Chrome's column (Lucas 2026-11-14: the chip's glyph centered 22 of 30 in), never under 2 pt.
    public static func chipLeading(bar: CGFloat, chromeColumn: Bool) -> CGFloat {
        guard chromeColumn else { return max(2, half(bar * 2 / 28)) }
        return max(2, (bar * 22 / 30 - (bar - 4) / 2).rounded())
    }

    /// Where the URL's text starts in a `bar` tall omnibar: Helium's 31 of 28 (2 + a 24 pt decoration + 5), or Chrome's
    /// 42 of 30 plus the field's own 3 pt of insets (its text column was the field's edge).
    public static func textOrigin(bar: CGFloat, chromeColumn: Bool) -> CGFloat {
        guard chromeColumn else { return half(bar * 31 / 28) }
        let chip = chipLeading(bar: bar, chromeColumn: true)
        return chip + (bar - 4) + max(5, (bar * 42 / 30 - chip - (bar - 4)).rounded()) + 3
    }

    /// Helium's tab x (imputnet/helium: tabs.patch's tab_close_button.cc and tab_style.cc, layout-constants.patch, with
    /// Chromium's rounded icons, which Helium turns on). Its icon and visible square are `kTabCloseButtonSize`, 14 pt; the
    /// icon is close_weight500_custom, 13.42 of its 24 units of ink with a 2.25 unit stroke (7.83 pt of ink, 1.31 pt
    /// stroke). The hover plate is a `RoundRectHighlightPathGenerator` with a 4 pt corner: at Helium's Default density
    /// (a 28 pt tab) the 14 pt square itself (the button's contents, `Insets::VH(1, 0)` off its 14 x 16), its end 6 pt
    /// inside the tab's end (the tab's 8 pt bottom extension and 2 pt of padding, less its 4 pt shape inset); at its
    /// Spacious density (a 32 pt tab) the whole 26 pt button less `Insets(1)`, 24 pt around the same 14 pt square, which
    /// sits 8 pt inside the tab's end (`kTabHorizontalPadding`), so the plate's end is 3 pt in. Highlight 16%, pressed
    /// 14%, of black or white (the tab's max contrast), with no fade.
    public struct HeliumClose: Equatable, Sendable {
        /// The tab's height, which picks the density: Spacious from 32 pt (Spacious's tab is 32 pt, Default's 28).
        public let row: CGFloat
        public init(row: CGFloat) { self.row = row }
        /// The x's icon and visible square: `kTabCloseButtonSize` with rounded icons.
        public var slot: CGFloat { 14 }
        /// The plate's corner: `kCornerRadius` in tab_close_button.cc.
        public var corner: CGFloat { 4 }
        /// The icon's ink: close_weight500_custom spans 13.42 of its 24 units, drawn at 14 pt.
        public var ink: CGFloat { 14 * 13.42 / 24 }
        /// Whether this tab draws Helium's Spacious x.
        public var isSpacious: Bool { row >= 32 }
        /// The plate's side: the 14 pt square at Default, the 24 pt button at Spacious.
        public var plateSide: CGFloat { isSpacious ? slot + 10 : slot }
        /// The visible square's inset from the tab's end: 6 at Default, 8 at Spacious.
        public var trailing: CGFloat { isSpacious ? 8 : 6 }
    }

    /// `points` of Helium's 28 pt row as the same share of `row`, in half points.
    public static func share(_ points: CGFloat, of row: CGFloat) -> CGFloat { half(row * points / 28) }

    private static func half(_ value: CGFloat) -> CGFloat { (value * 2).rounded() / 2 }
}
