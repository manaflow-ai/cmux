import AppKit
import CmuxNextActions
@testable import CmuxNextApp
@testable import CmuxNextDesign
import CmuxNextDesignTokens
import CmuxNextSettings
import Testing

/// The title area (Leo, 2026-11-11): "the contrast, I guess it's fine, but I feel like it may be too intense
/// for some people, so it needs to be adjustable. And then the glass for the selected top area, it's not the
/// same kind of transparency as the other bit."
///
/// `appearance.titleAreaContrast` scales the chrome's shade around the content (1, the default, is the shade
/// as it was), and the selected folder tab paints the content's own glass (`Palette.folderTabFill`) with the
/// shade cut away under it, so the tab and the content show the window's backdrop the same way.
@MainActor @Suite(.serialized) struct TitleAreaContrastTests {
    func snapshot(_ appearance: [String: JSONValue]) -> CmuxConfigSnapshot {
        CmuxConfigSnapshot.parse(.object(["appearance": .object(appearance)]), validDensities: SettingsApplier.validDensities,
                                 validMetrics: SettingsApplier.validMetrics)
    }

    /// `contrast` under Subtle Tone, the tone the contrast shades (one colour, the default, has no shade).
    func withContrast<T>(_ contrast: CGFloat, _ body: () throws -> T) rethrows -> T {
        let saved = (DesignSettings.shared.titleAreaContrast, DesignSettings.shared.titleAreaTone)
        DesignSettings.shared.titleAreaContrast = contrast
        DesignSettings.shared.titleAreaTone = .subtleTone
        defer { (DesignSettings.shared.titleAreaContrast, DesignSettings.shared.titleAreaTone) = saved }
        return try body()
    }

    /// The flush corner on for `body` (a Debug Settings pick of the default, goo, at Default density), so the
    /// tests of its frame always assert instead of returning early when the run's chrome left it off.
    func withFlushCorner<T>(_ body: () throws -> T) rethrows -> T {
        // Compact density keeps the pill before any override is read (`CornerFlush.current`): pin Default's.
        let density = DesignSettings.shared.densityTokens
        DesignSettings.shared.densityTokens = DensityPreset.cozy.tokens
        defer { DesignSettings.shared.densityTokens = density }
        let store = TunableStore.shared
        store.register([CornerFlush.tunable.descriptor])
        if !store.isActive { store.activate(file: nil) }
        let saved = store.set(CornerFlush.tunable.key, .choice(CornerFlush.goo.rawValue))
        defer { _ = store.set(CornerFlush.tunable.key, saved) }
        #expect(CornerFlush.current.isOn, "the pinned flush corner is off (compact density?)")
        return try body()
    }

    @Test func aMissingKeyIsTheDefaultAndTheDefaultIsOne() {
        let parsed = snapshot([:])
        #expect(TitleAreaContrastSetting.fallback == 1)
        #expect(TitleAreaContrastSetting.effective(in: parsed) == 1)
        #expect(!parsed.diagnostics.contains { $0.path == "appearance.titleAreaContrast" })
    }

    @Test func aNumberInRangeIsTakenAndOneOutsideIsClampedWithADiagnostic() {
        #expect(TitleAreaContrastSetting.effective(in: snapshot(["titleAreaContrast": .number(0.5)])) == 0.5)
        let loud = snapshot(["titleAreaContrast": .number(9)])
        #expect(TitleAreaContrastSetting.effective(in: loud) == TitleAreaContrastSetting.range.upperBound)
        #expect(loud.diagnostics.contains { $0.path == "appearance.titleAreaContrast" && $0.kind == .invalidValue })
        let word = snapshot(["titleAreaContrast": .string("loud")])
        #expect(TitleAreaContrastSetting.effective(in: word) == 1)
        #expect(word.diagnostics.contains { $0.path == "appearance.titleAreaContrast" && $0.kind == .invalidValue })
    }

    @Test func theSettingReachesTheDesignSettings() {
        let saved = DesignSettings.shared.titleAreaContrast
        defer { DesignSettings.shared.titleAreaContrast = saved }
        SettingsApplier.applyPlacement(snapshot(["titleAreaContrast": .number(0.65)]), to: DesignSettings.shared)
        #expect(abs(DesignSettings.shared.titleAreaContrast - 0.65) < 1e-9)
        SettingsApplier.applyPlacement(snapshot([:]), to: DesignSettings.shared)
        #expect(DesignSettings.shared.titleAreaContrast == 1)
    }

    /// The contrast scales the shade linearly, never past opaque black: on the flush corner's frame Subtle Tone's
    /// share of it (contrast 2 is the older two tones), on any other chrome the style's own shade.
    @Test(arguments: [true, false]) func theContrastScalesTheChromeShade(isDark: Bool) {
        withFlushCorner {
            let base = Metrics.mainPaneChromeShadeBase(isDark: isDark)
            for contrast in [0, 0.5, 1, 1.5, 2] as [CGFloat] {
                withContrast(contrast) {
                    #expect(abs(Metrics.mainPaneChromeShade(isDark: isDark) - min(1, base * TitleAreaTone.subtleShare * contrast)) < 1e-9)
                }
            }
            withContrast(2) { #expect(abs(Metrics.mainPaneChromeShade(isDark: isDark) - base) < 1e-9) }
        }
    }

    /// The folder tab paints what the content paints while the shade sets it apart; with no shade left it
    /// keeps the selection fill, so a selected tab always reads as selected.
    @Test func theFolderTabTakesTheContentsGlassOnlyWhileTheShadeReads() {
        withContrast(0) { #expect(Palette.folderTabFill == nil) }
        let isDark = ThemeScope.app.tokens.isDark
        withContrast(1) {
            let reads = Metrics.mainPaneChromeShade(isDark: isDark) >= Metrics.folderTabMinimumShade
            #expect((Palette.folderTabFill != nil) == reads)
            if reads { #expect(Palette.folderTabFill == Palette.paneFill) }
        }
        // Subtle Tone's light frame (0.045 of black) still opens a folder tab at half contrast: never a gray pill.
        #expect(0.045 * TitleAreaTone.subtleShare * 0.5 >= Metrics.folderTabMinimumShade)
    }

    /// The chrome's shade leaves the selected folder tabs out, as it leaves out the card: the tab shows the
    /// window's backdrop as the content does, and the tab row beside it stays shaded.
    @Test func theShadeLeavesTheFolderTabOut() throws {
        let view = MainPaneChromeShadeView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let card = CGRect(x: 10, y: 10, width: 380, height: 240) // the tab row is above it (maxY is the top)
        let folder = CGPath(rect: CGRect(x: 60, y: 250, width: 120, height: 30), transform: nil)
        view.update(card: card, radius: 12, alpha: 0.28, folders: [folder])
        let shade = try #require(view.layer?.sublayers?.compactMap { $0 as? CAShapeLayer }.first)
        let path = try #require(shade.path)
        let rule: CGPathFillRule = shade.fillRule == .evenOdd ? .evenOdd : .winding
        #expect(!path.contains(CGPoint(x: 120, y: 265), using: rule), "the folder tab is shaded")
        #expect(path.contains(CGPoint(x: 300, y: 265), using: rule), "the tab row beside the folder lost its shade")
        #expect(!path.contains(CGPoint(x: 200, y: 100), using: rule), "the card is shaded")
        view.update(card: card, radius: 12, alpha: 0.28, folders: [])
        let closed = try #require(shade.path)
        #expect(closed.contains(CGPoint(x: 120, y: 265), using: rule), "a deselected folder's hole stayed open")
    }

    /// The tab row's divider takes over from the tone as the shade drops (Leo, 2026-11-12: "THERE IS THE
    /// DIVIDER"): none at the full older shade, the rest of the shade scale between, full at one colour.
    @Test func theDividerStrengthGrowsAsTheContrastDrops() {
        for contrast in [0, 0.5, 1, 1.5, 2] as [CGFloat] {
            withContrast(contrast) {
                #expect(abs(Metrics.tabRowDividerStrength - min(1, max(0, 1 - Metrics.titleAreaShadeScale))) < 1e-9)
            }
        }
        withContrast(0) { #expect(Metrics.tabRowDividerStrength == 1) }
        withFlushCorner {
            withContrast(1) { #expect(abs(Metrics.tabRowDividerStrength - (1 - TitleAreaTone.subtleShare)) < 1e-9) }
            withContrast(2) { #expect(Metrics.tabRowDividerStrength == 0) }
        }
    }

    /// The divider runs along the card's top between its rounded corners; a square corner (the first tab
    /// selected, or the one-colour pill look) lets it reach the edge.
    @Test func theDividerLineSpansTheCardTopBetweenItsCorners() {
        let card = CGRect(x: 10, y: 10, width: 380, height: 240)
        #expect(CornerFlushChrome.dividerLine(card: card, radius: 12, squareLeading: false) == CGRect(x: 22, y: 250, width: 356, height: 0))
        #expect(CornerFlushChrome.dividerLine(card: card, radius: 12, squareLeading: true) == CGRect(x: 10, y: 250, width: 368, height: 0))
        #expect(CornerFlushChrome.dividerLine(card: card, radius: 0, squareLeading: true) == CGRect(x: 10, y: 250, width: 380, height: 0))
    }

    /// The divider's hairline sits on the card's top under the unselected tabs and leaves the selected folder
    /// tab out, so the folder still opens into the content; at the shipped contrast there is no line at all.
    @Test func theDividerLeavesTheFolderTabOut() throws {
        let view = MainPaneChromeShadeView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let card = CGRect(x: 10, y: 10, width: 380, height: 240)
        let folder = CGPath(rect: CGRect(x: 60, y: 240, width: 120, height: 40), transform: nil)
        let divider = CornerFlushChrome.dividerLine(card: card, radius: 12, squareLeading: false)
        let line = try #require(view.layer?.sublayers?.compactMap { $0 as? CAShapeLayer }.last)
        try withContrast(0.5) {
            view.update(card: card, radius: 12, alpha: 0.14, folders: [folder], divider: divider)
            guard Metrics.tabRowDividerStrength > 0 else { return }
            let path = try #require(line.path, "no divider at contrast 0.5")
            #expect(path.contains(CGPoint(x: 300, y: 250.2), using: .evenOdd), "no divider under the unselected tabs")
            #expect(!path.contains(CGPoint(x: 120, y: 250.2), using: .evenOdd), "the divider crosses the folder tab")
        }
        withContrast(2) {
            guard Metrics.tabRowDividerStrength == 0 else { return }
            view.update(card: card, radius: 12, alpha: 0.28, folders: [folder], divider: divider.offsetBy(dx: 1, dy: 0))
            #expect(line.path == nil, "the full older shade drew a divider")
        }
    }

    /// `appearance.titleAreaTone` (Leo, 2026-11-12: "he said he wanted to keep the default without the two tone"):
    /// a missing key is one colour; a bad value is one colour plus a diagnostic; the setting reaches the design.
    @Test func theToneParsesAndReachesTheDesignSettings() {
        #expect(TitleAreaToneSetting.fallback == .oneColor)
        #expect(DesignSettings().titleAreaTone == .oneColor)
        #expect(TitleAreaToneSetting.effective(in: snapshot([:])) == .oneColor)
        #expect(TitleAreaToneSetting.effective(in: snapshot(["titleAreaTone": .string("subtleTone")])) == .subtleTone)
        let bad = snapshot(["titleAreaTone": .string("twoTone")])
        #expect(TitleAreaToneSetting.effective(in: bad) == .oneColor)
        #expect(bad.diagnostics.contains { $0.path == "appearance.titleAreaTone" && $0.kind == .invalidValue })
        let saved = DesignSettings.shared.titleAreaTone
        defer { DesignSettings.shared.titleAreaTone = saved }
        SettingsApplier.applyPlacement(snapshot(["titleAreaTone": .string("subtleTone")]), to: DesignSettings.shared)
        #expect(DesignSettings.shared.titleAreaTone == .subtleTone)
        SettingsApplier.applyPlacement(snapshot([:]), to: DesignSettings.shared)
        #expect(DesignSettings.shared.titleAreaTone == .oneColor)
    }

    /// One Color moves every piece the contrast moves, together: no shade, the divider at full strength, and the
    /// selected tab back on its pill. Toggling back restores the contrast the slider holds, untouched.
    @Test(arguments: [true, false]) func oneColorMovesTheShadeDividerAndTabTogether(isDark: Bool) {
        withFlushCorner { oneColorMovesTogether(isDark: isDark) } // the tone is the flush corner frame's
    }

    func oneColorMovesTogether(isDark: Bool) {
        let saved = DesignSettings.shared.titleAreaTone
        defer { DesignSettings.shared.titleAreaTone = saved }
        withContrast(0.5) {
            DesignSettings.shared.titleAreaTone = .oneColor
            #expect(Metrics.mainPaneChromeShade(isDark: isDark) == 0)
            #expect(Metrics.tabRowDividerStrength == 1)
            #expect(Palette.folderTabFill == nil)
            #expect(DesignSettings.shared.titleAreaContrast == 0.5)
            DesignSettings.shared.titleAreaTone = .subtleTone
            let base = Metrics.mainPaneChromeShadeBase(isDark: isDark), scale = TitleAreaTone.subtleShare * 0.5
            #expect(abs(Metrics.mainPaneChromeShade(isDark: isDark) - base * scale) < 1e-9)
            #expect(abs(Metrics.tabRowDividerStrength - (1 - scale)) < 1e-9)
        }
    }

    /// One colour, the default, leaves the dividers to part the sidebar, the panes and the tab row from the content
    /// (Leo, 2026-11-12: "how about the divider tho? we still want to keep that... across most panes by default"):
    /// the theme's separator a step stronger, its hue kept, clear wherever the separator is (`appearance.borders`
    /// none), and the tab row's divider at full strength.
    @Test func oneColorKeepsAClearDividerFromTheSeparatorToken() {
        let separator = Palette.separator, divider = Palette.chromeDivider
        let strength = CGFloat(ChromeTunables.dividerStrength.value)
        #expect(abs(divider.alphaComponent - min(1, separator.alphaComponent * strength)) < 1e-6)
        #expect(ChromeTunables.dividerStrength.defaultValue > 1, "the chrome's dividers are no stronger than a list's hairline")
        if separator.alphaComponent > 0 { #expect(divider.alphaComponent > separator.alphaComponent) }
        withFlushCorner {
            let saved = DesignSettings.shared.titleAreaTone
            defer { DesignSettings.shared.titleAreaTone = saved }
            DesignSettings.shared.titleAreaTone = .oneColor
            #expect(Metrics.tabRowDividerStrength == 1)
            #expect(Metrics.mainPaneChromeShade(isDark: true) == 0 && Metrics.mainPaneChromeShade(isDark: false) == 0)
        }
    }

    /// The default tone flattens only the flush corner's frame: a picked chrome style (floating, blocks, card) keeps
    /// its own shade under One Color, scaled by the contrast alone.
    @Test func aPickedChromeStyleKeepsItsShadeUnderOneColor() {
        let design = DesignSettings.shared
        let saved = (design.chromeStyle, design.titleAreaTone)
        defer { (design.chromeStyle, design.titleAreaTone) = saved }
        design.titleAreaTone = .oneColor
        design.chromeStyle = .blocks
        guard !CornerFlush.current.isOn else { return }
        #expect(Metrics.titleAreaShadeScale == design.titleAreaContrast)
        if design.titleAreaContrast == 1 {
            #expect(Metrics.mainPaneChromeShade(isDark: true) == Metrics.mainPaneChromeShadeBase(isDark: true),
                    "One Color flattened the blocks style")
        }
    }

    /// #40282 made the flush corner the default, which made `Metrics.mainPaneCurved` true under the stock chrome,
    /// and three sidebar paths read that as "the card's edge is the seam": the sidebar's edge line shrank to the
    /// titlebar band and its hover and drag glow went dark. Leo, 2026-11-12: "slightly regressed the border thing,
    /// the border divider. And then there's, like, no more drag divider highlight". The default flush corner (not
    /// picked in Debug Settings) on a style that draws no curved card keeps the full-height line and the glow.
    @Test func theDefaultFlushCornerKeepsTheSidebarEdgeLineAndItsGlow() {
        let design = DesignSettings.shared
        guard ChromeTunables.mainPaneCurved.override == nil, !CornerFlush.isChosen,
              design.chromeStyle.curvedMainPane != true else { return }
        #expect(!Metrics.cardEdgeIsSidebarSeam)
        if CornerFlush.current.isOn { #expect(Metrics.mainPaneCurved, "the flush corner still draws the card") }
    }
}
