import CoreGraphics
import Testing
@testable import CmuxNextDesign

/// User (2026-10-02): "ensure bg of tabbar negative space is same as rest of
/// app. also we should visually differ the focused pane's tabs from
/// unfocused panes tabs by making the latter more subtle. all this should
/// be configurable by the user."
@MainActor
@Suite struct FocusIndicatorTests {
    private func tokens(_ name: String) -> ThemeTokens {
        ThemeTokens.derive(from: ThemeFixtures.all.first { $0.0 == name }!.1)
    }

    @Test func defaultsMarkBoth() {
        let design = DesignSettings()
        #expect(design.focusIndicator == .both)
        #expect(FocusIndicatorTunables.indicator.defaultValue == .both)
        #expect(FocusIndicatorTunables.inactiveTabStrength.defaultValue > 0)
    }

    @Test func onlyUnfocusedPanesOfASplitGoSubtle() {
        func cue(_ focused: Bool, _ count: Int, _ indicator: FocusIndicator) -> ChromeEmphasis {
            .forPane(isFocused: focused, paneCount: count, indicator: indicator, style: .fade, strength: 0.45)
        }
        #expect(cue(false, 2, .both) == .subtle(.fade, strength: 0.45))
        #expect(cue(false, 2, .tabs) == .subtle(.fade, strength: 0.45))
        #expect(cue(true, 2, .both) == .full)
        #expect(cue(false, 1, .both) == .full)
        #expect(cue(false, 2, .border) == .full)
        #expect(cue(false, 2, .none) == .full)
        #expect(ChromeEmphasis.forPane(isFocused: false, paneCount: 2, indicator: .both, style: .tonal, strength: 0) == .full)
        #expect(FocusIndicator.both.marksBorder && FocusIndicator.border.marksBorder)
        #expect(!FocusIndicator.tabs.marksBorder && !FocusIndicator.none.marksBorder)
    }

    /// Every variant lowers the contrast of tab text and pill fills, keeps
    /// the theme's hues, and still tells the selected tab from the others.
    @Test(arguments: ThemeFixtures.all.map(\.0), InactiveTabStyle.allCases)
    func subtleTabsAreQuieterButKeepTheSelection(_ name: String, _ style: InactiveTabStyle) {
        let full = tokens(name)
        let quiet = full.emphasized(.subtle(style, strength: 0.45))
        let page = full.contentBackground.withAlpha(1)
        #expect(quiet.textPrimary.contrast(with: page) < full.textPrimary.contrast(with: page), "\(name) \(style)")
        #expect(quiet.textSecondary.contrast(with: page) < full.textSecondary.contrast(with: page), "\(name) \(style)")
        #expect(quiet.selectionFill.composited(over: page).contrast(with: page)
                    < full.selectionFill.composited(over: page).contrast(with: page), "\(name) \(style)")
        // The selected tab (primary text) still reads above the others (secondary).
        #expect(quiet.textPrimary.contrast(with: page) > quiet.textSecondary.contrast(with: page), "\(name) \(style)")
        // Same surfaces, so the strip's negative space does not change.
        #expect(quiet.contentBackground == full.contentBackground && quiet.windowBackground == full.windowBackground)
        #expect(full.emphasized(.full) == full)
    }

    /// Even at full strength every tier stays readable and the selected
    /// tab stays above the others.
    @Test(arguments: ThemeFixtures.all.map(\.0), InactiveTabStyle.allCases)
    func subtleTextKeepsItsFloors(_ name: String, _ style: InactiveTabStyle) {
        let full = tokens(name)
        let page = full.contentBackground.withAlpha(1)
        for strength in [CGFloat(0.35), 1] {
            let quiet = full.emphasized(.subtle(style, strength: strength))
            func holds(_ got: ThemeRGB, _ was: ThemeRGB, _ floor: Double) -> Bool {
                got.contrast(with: page) >= min(floor, was.contrast(with: page)) - 0.01
            }
            #expect(holds(quiet.textPrimary, full.textPrimary, ThemeTokens.subtlePrimaryFloor), "\(name) \(style) \(strength)")
            #expect(holds(quiet.textSecondary, full.textSecondary, ThemeTokens.subtleSecondaryFloor), "\(name) \(style) \(strength)")
            #expect(holds(quiet.textTertiary, full.textTertiary, ThemeTokens.subtleTertiaryFloor), "\(name) \(style) \(strength)")
            #expect(quiet.textPrimary.contrast(with: page) > quiet.textSecondary.contrast(with: page), "\(name) \(style) \(strength)")
        }
    }

    /// A strip scope's emphasis colors only its own views; a child scope
    /// keeps the plain colors.
    @Test func aScopesEmphasisAppliesToItsOwnViewsOnly() {
        let parent = ThemeScope(level: .workspace)
        let strip = ThemeScope(level: .terminal, parent: parent)
        let child = ThemeScope(level: .terminal, parent: strip)
        let before = strip.generation
        strip.setEmphasis(.subtle(.fade, strength: 0.45), animated: false)
        #expect(strip.tokens == parent.tokens.emphasized(.subtle(.fade, strength: 0.45)))
        #expect(child.tokens == parent.tokens)
        #expect(strip.generation == before + 1)
        // Panels and hover cards opened from the strip draw at full strength.
        #expect(strip.fullStrength === parent)
        strip.setEmphasis(.full, animated: false)
        #expect(strip.tokens == parent.tokens)
    }
}
