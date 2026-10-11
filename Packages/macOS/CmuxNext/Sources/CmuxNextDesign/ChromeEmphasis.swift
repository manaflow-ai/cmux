public import CoreGraphics

/// How an unfocused pane's tabs draw subtler (`focus.inactiveTabStyle` in
/// cmux.json; `fade` is the default).
public nonisolated enum InactiveTabStyle: String, Sendable, CaseIterable, Codable, TunableChoice {
    /// Text, icons and pill fills fade toward the background by the strength.
    case fade
    /// Every text tier steps down one tier; the selected pill takes the
    /// hover fill.
    case tonal
    /// No pill fill; the selected tab is marked by its text tier only.
    case quiet

    public var tunableTitle: String {
        switch self {
        case .fade: "Fade"
        case .tonal: "Tonal"
        case .quiet: "Quiet"
        }
    }
}

/// How strongly a pane's chrome (its tab strip) draws.
public nonisolated enum ChromeEmphasis: Hashable, Sendable {
    case full
    case subtle(InactiveTabStyle, strength: CGFloat)

    /// The emphasis for one pane's tabs: full for the focused pane, for the
    /// only pane, and when the indicator does not mark tabs; else subtle.
    public static func forPane(isFocused: Bool, paneCount: Int, indicator: FocusIndicator,
                               style: InactiveTabStyle, strength: CGFloat) -> ChromeEmphasis {
        guard indicator.marksTabs, paneCount > 1, !isFocused, strength > 0 else { return .full }
        return .subtle(style, strength: min(max(strength, 0), 1))
    }
}

extension ThemeTokens {
    /// Contrast floors for subtle tab text against the page: the selected
    /// tab stays readable, and every tier stays visible.
    public nonisolated static let subtlePrimaryFloor = 3.5
    public nonisolated static let subtleSecondaryFloor = 2.5
    public nonisolated static let subtleTertiaryFloor = 2.0

    /// These tokens with a pane's chrome emphasis applied: lower-contrast
    /// text and pill fills for a subtle pane, the same hues (no accent),
    /// never below the subtle floors (or the original, when that is lower).
    public nonisolated func emphasized(_ emphasis: ChromeEmphasis) -> ThemeTokens {
        guard case let .subtle(style, strength) = emphasis else { return self }
        var t = self
        let s = Double(strength)
        let page = contentBackground.withAlpha(1)
        func fade(_ color: ThemeRGB, _ fraction: Double, floor: Double) -> ThemeRGB {
            let target = min(floor, color.contrast(with: page))
            var f = fraction
            while f > 0, color.mixed(toward: page, f).contrast(with: page) < target { f -= 0.02 }
            return color.mixed(toward: page, max(f, 0))
        }
        switch style {
        case .fade:
            t.textPrimary = fade(textPrimary, s, floor: Self.subtlePrimaryFloor)
            t.textSecondary = fade(textSecondary, s, floor: Self.subtleSecondaryFloor)
            t.textTertiary = fade(textTertiary, s, floor: Self.subtleTertiaryFloor)
            t.selectionFill = selectionFill.withAlpha(selectionFill.alpha * (1 - s))
            t.hoverFill = hoverFill.withAlpha(hoverFill.alpha * (1 - s))
        case .tonal:
            t.textPrimary = textSecondary
            t.textSecondary = textTertiary
            t.textTertiary = fade(textTertiary, s * 0.5, floor: Self.subtleTertiaryFloor)
            t.selectionFill = hoverFill.withAlpha(hoverFill.alpha * (1 - s * 0.5))
        case .quiet:
            t.textPrimary = textSecondary
            t.textSecondary = fade(textTertiary, s * 0.5, floor: Self.subtleSecondaryFloor)
            t.textTertiary = fade(textTertiary, s * 0.5, floor: Self.subtleTertiaryFloor)
            t.selectionFill = selectionFill.withAlpha(0)
        }
        return t
    }
}
