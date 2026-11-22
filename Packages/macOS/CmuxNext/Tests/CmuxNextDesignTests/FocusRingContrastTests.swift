import Testing
@testable import CmuxNextDesign

/// The pane focus ring is subtle by default (user: "we need focus ring to be
/// subtler by default somehow. color subtler"): a quieter tone of the Ghostty
/// foreground, no accent hue, still stronger than the pane border so the
/// focused pane can be found.
@Suite struct FocusRingContrastTests {
    private func tokens(_ name: String) -> ThemeTokens {
        ThemeTokens.derive(from: ThemeFixtures.all.first { $0.0 == name }!.1)
    }

    /// The ring's share of the foreground for a contrast level, from the
    /// color the overlay draws.
    private func foregroundShare(_ t: ThemeTokens, _ contrast: FocusRingContrast) -> Double {
        var settings = FocusRingSettings()
        settings.contrast = contrast
        return settings.ringColor(in: t, override: nil).alpha
    }

    /// Contrast of a foreground share over the content background, minus 1
    /// (0 is invisible).
    private func visibility(_ t: ThemeTokens, share: Double) -> Double {
        let bg = t.contentBackground.withAlpha(1)
        return t.focusRing.withAlpha(share).composited(over: bg).contrast(with: bg) - 1
    }

    @Test func theDefaultIsSubtle() {
        #expect(FocusRingSettings().contrast == .subtle)
    }

    @Test(arguments: ThemeFixtures.all.map(\.0))
    func subtleIsQuieterThanBeforeButStillFindable(_ name: String) {
        let t = tokens(name)
        let subtle = foregroundShare(t, .subtle)
        // At most a quarter of the foreground (before: 55%, kept as standard).
        #expect(subtle <= 0.25, "\(name) \(subtle)")
        #expect(foregroundShare(t, .standard) == 0.55, "\(name)")
        #expect(subtle < foregroundShare(t, .standard), "\(name)")
        #expect(foregroundShare(t, .standard) < foregroundShare(t, .strong), "\(name)")
        // Clearly stronger than a pane border, so it marks the focused pane.
        let border = visibility(t, share: t.paneBorder.alpha)
        #expect(visibility(t, share: subtle) > border * 1.4, "\(name) ring \(visibility(t, share: subtle)) border \(border)")
    }

    @Test(arguments: ThemeFixtures.all.map(\.0))
    func theRingIsTheThemeForegroundWithNoAccentHue(_ name: String) {
        let input = ThemeFixtures.all.first { $0.0 == name }!.1
        #expect(tokens(name).focusRing.withAlpha(1) == input.foreground.withAlpha(1), "\(name)")
    }

    @Test func theDebugOverrideWinsAndAnExplicitColorWinsOverBoth() {
        let t = tokens(ThemeFixtures.all[0].0)
        #expect(FocusRingSettings().ringColor(in: t, override: 0.9).alpha == 0.9)
        var custom = FocusRingSettings()
        custom.color = ThemeRGB(hex: 0xFF8800)
        #expect(custom.ringColor(in: t, override: 0.9) == ThemeRGB(hex: 0xFF8800))
    }
}
