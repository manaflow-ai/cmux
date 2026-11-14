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
public nonisolated enum BrowserChromeTuning {
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
        switch metric {
        case .rowHeight, .rowGap: return metric.token.flatMap { tokens.tokens[$0] }.map { CGFloat($0) } ?? 0
        case .closeSize: return share(14, of: row)
        case .closeCorner: return half(share(14, of: row) * 4 / 14)
        case .closeInk: return share(8, of: row)
        case .closeTrailing: return share(6, of: row)
        case .closeHoverOpacity: return 16 // tab_close_button.cc's highlight opacity, at every density
        case .chipLeading: return chipLeading(bar: row, chromeColumn: chromeColumn)
        case .textOrigin: return textOrigin(bar: row, chromeColumn: chromeColumn)
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

    /// `points` of Helium's 28 pt row as the same share of `row`, in half points.
    public static func share(_ points: CGFloat, of row: CGFloat) -> CGFloat { half(row * points / 28) }

    private static func half(_ value: CGFloat) -> CGFloat { (value * 2).rounded() / 2 }
}
