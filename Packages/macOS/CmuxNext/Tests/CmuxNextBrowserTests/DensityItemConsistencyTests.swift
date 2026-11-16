import AppKit
@testable import CmuxNextBrowser
import CmuxNextDesign
import CmuxNextTestSupport
import Testing

/// Each built-in density draws a browser's chrome (Lucas 2026-11-14, measured and read in outputs/2026-11-14-helium-match):
/// Default is Helium 0.21.2's tabs (29 pt rows and tabs, the 28 pt location bar, 8 pt corners, a 12 pt
/// dropdown corner), Comfortable is roomier (40 pt rows and tabs, the 34 pt location bar, 40 pt dropdown rows),
/// Spacious that grown with its text. Every density keeps Default's roundness on its own heights (Lucas 2026-11-14). Compact and Ultra-compact keep one 20 pt row for all three with
/// Chrome's ratio corner (8 on 30).
@MainActor @Suite(.serialized) struct DensityItemConsistencyTests {
    struct Expected {
        var omnibar: CGFloat, tab: CGFloat, row: CGFloat
        var omnibarRadius: CGFloat, cardRadius: CGFloat, tabRadius: CGFloat, rowRadius: CGFloat
    }

    nonisolated static let expected: [DensityPreset: Expected] = Dictionary(uniqueKeysWithValues:
        zip(DensityPreset.allCases, [24.0, 28, 30, 32, 36]).map { preset, row in
            let t = preset.scaleFactor, o = preset.omnibarScaleFactor // Default's omnibar is Compact's
            func half(_ value: Double) -> Double { (value * 2).rounded() / 2 }
            return (preset, Expected(omnibar: half(29 * o), tab: row, row: row,
                                     omnibarRadius: half(8 * o), cardRadius: half(12 * o), tabRadius: half(9 * t), rowRadius: half(9 * t)))
        })

    private func inDensity(_ preset: DensityPreset, _ body: () throws -> Void) rethrows {
        // Scoped, so the app-wide settings (and every other suite) are never touched.
        try OmnibarGlassAppearance.$scoped.withValue(OmnibarGlassAppearance()) {
            try DensityTokens.$scoped.withValue(preset.tokens) { try body() }
        }
    }

    @Test(arguments: DensityPreset.allCases)
    func omnibarTabAndRowTakeTheBrowsersHeights(preset: DensityPreset) throws {
        let want = try #require(Self.expected[preset])
        inDensity(preset) {
            #expect(OmnibarMetrics.current.barHeight == want.omnibar, "\(preset): omnibar \(OmnibarMetrics.current.barHeight)")
            #expect(Metrics.tabHeight == want.tab, "\(preset): tab \(Metrics.tabHeight)")
            #expect(SidebarRowTokens.current.listRowHeight == want.row, "\(preset): row fill \(SidebarRowTokens.current.listRowHeight)")
        }
    }

    @Test(arguments: DensityPreset.allCases)
    func omnibarTabAndRowTakeTheBrowsersCorners(preset: DensityPreset) throws {
        let want = try #require(Self.expected[preset])
        inDensity(preset) {
            let omnibar = OmnibarGlassLook.current.resolvedCornerRadius(barHeight: OmnibarStyle.barHeight)
            #expect(omnibar == want.omnibarRadius, "\(preset): omnibar radius \(omnibar)")
            #expect(OmnibarStyle.cardCornerRadius == want.cardRadius, "\(preset): dropdown radius \(OmnibarStyle.cardCornerRadius)")
            #expect(Metrics.tabCornerRadius == want.tabRadius, "\(preset): tab radius \(Metrics.tabCornerRadius)")
            #expect(SidebarRowTokens.current.listRowCornerRadius == want.rowRadius,
                    "\(preset): row radius \(SidebarRowTokens.current.listRowCornerRadius)")
            // The highlighted suggestion row is concentric with the card across its inset.
            #expect(abs(OmnibarStyle.rowCornerRadius - (OmnibarStyle.cardCornerRadius - OmnibarStyle.rowSideInset)) < 0.0001
                || OmnibarStyle.rowSideInset == OmnibarStyle.edgeInset, "\(preset): the highlighted row is not concentric")
        }
    }

    /// The omnibar's text fits its shorter bar: never clipped (`minimumBarHeight`), so equal height
    /// never costs a cut glyph.
    @Test(arguments: DensityPreset.allCases)
    func omnibarTextFitsTheSharedHeight(preset: DensityPreset) {
        inDensity(preset) {
            let metrics = OmnibarMetrics.current
            #expect(OmnibarMetrics.minimumBarHeight(fontSize: metrics.fontSize) <= metrics.barHeight,
                    "\(preset): \(metrics.fontSize) pt text in a \(metrics.barHeight) pt bar")
        }
    }
}
