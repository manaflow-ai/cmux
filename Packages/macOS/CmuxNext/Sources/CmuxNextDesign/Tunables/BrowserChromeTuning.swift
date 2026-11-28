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
        let factor = tokens.uniformScale ?? 1
        let sizeRow = tokens.uniformScale == nil ? row : CGFloat(DensityPreset.referenceTokens.tokens["browserRowHeight"] ?? 28)
        // A density's own value (the Density Playground's tab close button tokens) wins over Helium's share.
        if let key = metric.densityKey, let exact = tokens.tokens[key] { return CGFloat(exact) }
        switch metric {
        case .rowHeight, .rowGap: return metric.token.flatMap { tokens.tokens[$0] }.map { CGFloat($0) } ?? 0
        case .closeSize: return half(share(14, of: sizeRow) * factor)
        // The density's own tab corner; `TabStripMetrics` draws the corner of the pill it lays out (a capsule tab's too).
        case .closeCorner:
            let radius = tokens.tokens["tabCornerRadius"].map { CGFloat($0) } ?? (row * 8 / 28).rounded()
            return closePlate(pillHeight: row, pillRadius: radius, slot: half(share(14, of: sizeRow) * factor), maximumSide: row).corner
        case .closeInk: return half(share(8, of: sizeRow) * factor)
        case .closeTrailing: return concentricTrailing(row: row, closeSize: half(share(14, of: sizeRow) * factor))
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

    /// The tab x's hover plate in a pill `height` tall with corner `radius` (Lawrence msg 48706: "match helium in terms of
    /// shape + hover ... and be concentric with the tab roundness itself"). Helium's 14 pt square with a 4 pt corner at its
    /// Default density cannot nest in its 8 pt tab corner; its Spacious one can and does (tab_close_button.cc on a 32 pt
    /// tab: `Insets(1)` gives a 24 pt plate 4 pt inside the pill, rounded 4 = 8 - 4). That plate at every density: set
    /// half the pill's corner in from its top, bottom and end (2 pt at least), between the x's `slot` and `maximumSide`,
    /// rounded with what is left of the pill's corner (``ConcentricCorners``). A capsule tab gets a circle.
    public static func closePlate(pillHeight height: CGFloat, pillRadius radius: CGFloat, slot: CGFloat,
                                  maximumSide: CGFloat) -> (side: CGFloat, corner: CGFloat) {
        let outer = max(0, min(radius, height / 2))
        let side = min(max(slot, height - 2 * max(2, outer / 2)), max(slot, min(maximumSide, height)))
        let corners = ConcentricCorners(outer: outer, padding: 0)
        let corner = corners.radius(fitting: CGSize(width: side, height: side), radius: corners.nested(in: outer, inset: (height - side) / 2))
        return (side, corner)
    }

    /// The x's slot inset from the pill's end that puts its center half a `row` in, so its plate (``closePlate``) is as
    /// far from the pill's end as from its top and bottom; in half points.
    public static func concentricTrailing(row: CGFloat, closeSize: CGFloat) -> CGFloat { max(0, half((row - closeSize) / 2)) }

    /// `points` of Helium's 28 pt row as the same share of `row`, in half points.
    public static func share(_ points: CGFloat, of row: CGFloat) -> CGFloat { half(row * points / 28) }

    private static func half(_ value: CGFloat) -> CGFloat { (value * 2).rounded() / 2 }
}
