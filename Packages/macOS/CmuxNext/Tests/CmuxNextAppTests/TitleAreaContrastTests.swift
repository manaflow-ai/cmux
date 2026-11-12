import AppKit
import CmuxNextActions
@testable import CmuxNextApp
@testable import CmuxNextDesign
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

    func withContrast<T>(_ contrast: CGFloat, _ body: () throws -> T) rethrows -> T {
        let saved = DesignSettings.shared.titleAreaContrast
        DesignSettings.shared.titleAreaContrast = contrast
        defer { DesignSettings.shared.titleAreaContrast = saved }
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

    /// The default draws the shade exactly as before; other values scale it, never past opaque black.
    @Test(arguments: [true, false]) func theContrastScalesTheChromeShade(isDark: Bool) {
        let base = Metrics.mainPaneChromeShadeBase(isDark: isDark)
        withContrast(1) { #expect(Metrics.mainPaneChromeShade(isDark: isDark) == base) }
        withContrast(0.5) { #expect(abs(Metrics.mainPaneChromeShade(isDark: isDark) - base * 0.5) < 1e-9) }
        withContrast(1.5) { #expect(abs(Metrics.mainPaneChromeShade(isDark: isDark) - min(1, base * 1.5)) < 1e-9) }
        withContrast(0) { #expect(Metrics.mainPaneChromeShade(isDark: isDark) == 0) }
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
        // The default light shade (0.045) still reads at half contrast.
        #expect(0.045 * 0.5 >= Metrics.folderTabMinimumShade)
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

    /// The tab row's divider takes over from the tone as the contrast drops (Leo, 2026-11-12: "THERE IS THE
    /// DIVIDER"): none at the shipped contrast, half at 0.5, full at one colour.
    @Test func theDividerStrengthGrowsAsTheContrastDrops() {
        withContrast(1) { #expect(Metrics.tabRowDividerStrength == 0) }
        withContrast(1.5) { #expect(Metrics.tabRowDividerStrength == 0) }
        withContrast(0.5) { #expect(abs(Metrics.tabRowDividerStrength - 0.5) < 1e-9) }
        withContrast(0) { #expect(Metrics.tabRowDividerStrength == 1) }
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
            let path = try #require(line.path, "no divider at contrast 0.5")
            #expect(path.contains(CGPoint(x: 300, y: 250.2), using: .evenOdd), "no divider under the unselected tabs")
            #expect(!path.contains(CGPoint(x: 120, y: 250.2), using: .evenOdd), "the divider crosses the folder tab")
        }
        withContrast(1) {
            view.update(card: card, radius: 12, alpha: 0.28, folders: [folder], divider: divider.offsetBy(dx: 1, dy: 0))
            #expect(line.path == nil, "the shipped contrast drew a divider")
        }
    }
}
