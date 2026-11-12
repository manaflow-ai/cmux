import AppKit
@testable import CmuxNextBrowser
import CmuxNextDesign
import CmuxNextTestSupport
import Testing

/// Lawrence 2026-11-11: "omnibar height should be same as tabbar tab height which should be same as
/// workspace rows height", with "same roundness as chrome". At every built-in density the omnibar, a
/// tab pill and a sidebar workspace row's fill are one height (``Metrics/chromeRowHeight``) and one corner
/// radius, Chrome's.
///
/// The radius is Chromium's: its free-standing rounded-rect tab (the vertical tab strip's tab,
/// the same shape as a cmux tab pill or sidebar row) is `kVerticalTabHeight` 30 tall with
/// `kVerticalTabCornerRadius` 8 (chrome/browser/ui/layout_constants.cc at chromium main
/// f1b4f9c05eb7). Every density keeps that 8:30 ratio, so Default (30 pt) draws Chrome's tab exactly.
@MainActor @Suite(.serialized) struct DensityItemConsistencyTests {
    /// The one chrome row per built-in density: Comfortable is Chrome's `kLocationBarHeight` (34),
    /// Default Chrome's `kVerticalTabHeight` (30, also the Codex sidebar row), Compact today's 24 pt
    /// tab and row, Ultra-compact a 20 pt row with 11 pt omnibar text.
    nonisolated static let expectedHeight: [DensityPreset: CGFloat] = [
        .ultraCompact: 20, .compact: 24, .cozy: 30, .comfortable: 34, .spacious: 42,
    ]

    /// Chromium's ratio (8 on 30), rounded to whole points.
    nonisolated static func chromeRadius(_ height: CGFloat) -> CGFloat { (height * 8 / 30).rounded() }

    private func inDensity(_ preset: DensityPreset, _ body: () throws -> Void) rethrows {
        // Scoped, so the app-wide settings (and every other suite) are never touched.
        try OmnibarGlassAppearance.$scoped.withValue(OmnibarGlassAppearance()) {
            try DensityTokens.$scoped.withValue(preset.tokens) { try body() }
        }
    }

    @Test(arguments: DensityPreset.allCases)
    func omnibarTabAndRowShareOneHeight(preset: DensityPreset) throws {
        let expected = try #require(Self.expectedHeight[preset])
        inDensity(preset) {
            let omnibar = OmnibarMetrics.current.barHeight
            let tab = Metrics.tabHeight
            let row = SidebarRowTokens.current.listRowHeight
            #expect(omnibar == expected, "\(preset): omnibar \(omnibar), want \(expected)")
            #expect(tab == expected, "\(preset): tab \(tab), want \(expected)")
            #expect(row == expected, "\(preset): sidebar row fill \(row), want \(expected)")
        }
    }

    @Test(arguments: DensityPreset.allCases)
    func omnibarTabAndRowShareChromesRoundness(preset: DensityPreset) throws {
        let height = try #require(Self.expectedHeight[preset])
        let chrome = Self.chromeRadius(height)
        inDensity(preset) {
            let omnibar = OmnibarStyle.cardCornerRadius
            let tab = Metrics.tabCornerRadius
            let row = tab  // rows draw the tab radius (SidebarDensityTokens.rowCornerRadius)
            #expect(omnibar == chrome, "\(preset): omnibar radius \(omnibar), Chrome's \(chrome)")
            #expect(tab == chrome, "\(preset): tab radius \(tab), Chrome's \(chrome)")
            #expect(row == chrome, "\(preset): row radius \(row), Chrome's \(chrome)")
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
