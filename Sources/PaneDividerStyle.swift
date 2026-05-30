import AppKit

/// Resolved appearance of the separator bar drawn between split panes.
///
/// `PaneDividerStyle` is the substrate-independent contract for divider
/// styling. It is resolved once from configuration (cmux config, then the
/// Ghostty `split-divider-color`, then a built-in default) and then applied by
/// whichever split substrate is hosting the panes. Today that is Bonsplit, but
/// the contract intentionally carries no Bonsplit types so it survives the
/// split-substrate migration tracked in #2289 / #4241 / #2096.
struct PaneDividerStyle: Equatable {
    /// Explicit divider color. When `nil`, the divider color is derived from
    /// the pane's chrome background (with a modest contrast boost) so the
    /// default still adapts to light and dark themes.
    var color: NSColor?

    /// Divider thickness in points.
    var thickness: CGFloat

    /// Default divider thickness, in points.
    ///
    /// Bumped from the historical 1pt hairline to 2pt: the reporter on #5006
    /// found the 1px divider too subtle, and the dominant lever for visibility
    /// is thickness. 2pt survives Retina rounding while staying understated,
    /// and remains configurable down to a hairline via `ui.paneDivider`.
    static let defaultThickness: CGFloat = 2

    /// Inclusive lower bound for a configured thickness.
    static let minimumThickness: CGFloat = 0
    /// Inclusive upper bound for a configured thickness.
    static let maximumThickness: CGFloat = 12

    /// Multiplier applied to the theme-derived separator alpha for the default
    /// divider, making it modestly more visible than the legacy hairline while
    /// keeping the same theme-native hue.
    static let defaultContrastBoost: CGFloat = 1.4

    /// The built-in default style: theme-derived color, 2pt thick.
    static let `default` = PaneDividerStyle(color: nil, thickness: defaultThickness)

    /// Resolve the effective divider style from its configuration layers.
    ///
    /// Precedence: cmux config (`override`) wins over the Ghostty
    /// `split-divider-color`, and both win over the built-in default. Thickness
    /// is sourced only from cmux config (Ghostty has no divider-thickness key).
    ///
    /// - Parameters:
    ///   - override: The resolved cmux-config divider override (global merged
    ///     with project-scoped `.cmux/cmux.json`).
    ///   - ghosttyDividerColor: The parsed Ghostty `split-divider-color`, if set.
    /// - Returns: The fully resolved ``PaneDividerStyle``.
    static func resolved(
        override: CmuxPaneDividerOverride,
        ghosttyDividerColor: NSColor?
    ) -> PaneDividerStyle {
        let color = override.color ?? ghosttyDividerColor
        let thickness = clampThickness(override.thickness ?? defaultThickness)
        return PaneDividerStyle(color: color, thickness: thickness)
    }

    /// Clamp a thickness into the supported range, falling back to the default
    /// for non-finite input.
    static func clampThickness(_ value: CGFloat) -> CGFloat {
        guard value.isFinite else { return defaultThickness }
        return min(max(value, minimumThickness), maximumThickness)
    }

    /// The concrete divider color for a given pane chrome background.
    ///
    /// Returns the explicit ``color`` when set; otherwise derives a
    /// more-visible default from the chrome background.
    func resolvedColor(forChromeBackground background: NSColor) -> NSColor {
        if let color { return color }
        return PaneDividerStyle.defaultDerivedColor(forChromeBackground: background)
    }

    /// The `#RRGGBBAA` hex string Bonsplit consumes as its `borderHex`.
    func borderHex(forChromeBackground background: NSColor) -> String {
        resolvedColor(forChromeBackground: background).hexString(includeAlpha: true)
    }

    /// Derive the default divider color from the chrome background.
    ///
    /// Uses the existing ``WindowChromeSeparatorColor`` derivation (so the hue
    /// still matches the theme and light/dark are handled), then boosts the
    /// alpha by ``defaultContrastBoost`` so the default divider reads more
    /// clearly than the legacy near-invisible hairline.
    static func defaultDerivedColor(forChromeBackground background: NSColor) -> NSColor {
        let base = WindowChromeSeparatorColor.color(forChromeBackground: background)
        let boostedAlpha = min(1.0, base.alphaComponent * defaultContrastBoost)
        return base.withAlphaComponent(boostedAlpha)
    }
}
