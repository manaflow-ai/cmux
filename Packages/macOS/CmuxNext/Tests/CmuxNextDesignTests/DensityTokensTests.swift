import AppKit
@testable import CmuxNextDesign
import Testing

/// Built-ins scale Default; custom densities keep their interpolation and overrides.
@MainActor @Suite struct DensityTokensTests {
    private static func typeSizes() -> [CGFloat] {
        [Typography.body, Typography.bodyEmphasized, Typography.caption, Typography.header, Typography.search,
         Typography.shortcut, Typography.title, Typography.subtitle].map(\.pointSize)
    }

    @Test func defaultKeepsItsReferenceGeometry() {
        DensityTokens.$scoped.withValue(DensityPreset.cozy.tokens) {
            #expect(Metrics.chromeRowHeight == 30)
            #expect(Metrics.sidebarRowHeight == 28)
            #expect(Typography.tabTitle.pointSize == 14)
            #expect(Metrics.tabIconSize == 16.5)
            #expect(Metrics.tabStripHeight == 36)
            #expect(Metrics.space1 == 2)
        }
    }

    /// Lucas 2026-11-17: "the default omnibar should be the same as compact omnibar, we should match them exactly".
    /// Every `omnibar*` size of Default is Compact's, and the bar, its text, icons and buttons resolve alike.
    @Test func defaultsOmnibarIsCompacts() {
        let cozy = DensityPreset.cozy.tokens, compact = DensityPreset.compact.tokens
        let keys = compact.tokens.keys.filter { $0.hasPrefix("omnibar") } + ["toolbarGlyphSize"]
        #expect(keys.count > 10)
        for key in keys { #expect(cozy.tokens[key] == compact.tokens[key], "omnibar token \(key)") }
        #expect(cozy.fontToken("omnibarFontSize") == compact.fontToken("omnibarFontSize"))
        #expect(cozy.toolbarButtonSize == compact.toolbarButtonSize && cozy.toolbarGlyphSize == compact.toolbarGlyphSize)
    }

    @Test func theInitialDensityIsCompact() {
        #expect(DesignSettings().densityTokens == DensityPreset.compact.tokens)
    }

    @Test(arguments: DensityPreset.allCases)
    func everySizeKeepsDefaultsProportions(preset: DensityPreset) throws {
        let reference = DensityPreset.cozy.tokens
        let tokens = preset.tokens
        let t = preset.scaleFactor
        func half(_ value: Double) -> Double { (value * 2).rounded() / 2 }
        #expect(Set(tokens.tokens.keys) == Set(reference.tokens.keys))
        let rows: [DensityPreset: Double] = [.ultraCompact: 24, .compact: 28, .cozy: 30, .comfortable: 32, .spacious: 36]
        let row = try #require(rows[preset])
        #expect(tokens.tokens["browserRowHeight"] == row)
        #expect(try #require(tokens.tokens["sidebarRowHeight"]) + half(2 * t) == row)
        #expect(tokens.tokens["tabStripHeight"] == row + 2 * half(3 * t))
        #expect(tokens.spacing == t)
        #expect(tokens.fontSize == 14 * t)
        let ratios = ["sidebarLineBoxBaseline", "omnibarLineBoxBaseline", "densityScale", "composerZoom"]
        let fonts = ["tabTitleSize", "sidebarTitleSize", "omnibarFontSize"]
        let exceptions = ratios + ["sidebarRowHeight", "browserRowHeight", "tabStripHeight"]
        // Default's omnibar is Compact's (`defaultsOmnibarIsCompacts`); everything else is Default's reference times t.
        let omnibarT = preset.omnibarScaleFactor
        func factor(_ key: String) -> Double { DensityPreset.isOmnibarToken(key) ? omnibarT : t }
        for (key, unscaled) in DensityPreset.referenceTokens.tokens where !exceptions.contains(key) {
            let value = try #require(tokens.tokens[key])
            let expected = fonts.contains(key) ? unscaled * factor(key) : half(unscaled * factor(key))
            #expect(value == expected, "\(preset): \(key)")
            if !fonts.contains(key) { #expect(value * 2 == (value * 2).rounded()) }
        }
        for key in ["sidebarLineBoxBaseline", "omnibarLineBoxBaseline"] { #expect(tokens.tokens[key] == reference.tokens[key]) }
        for key in ["densityScale", "composerZoom"] { #expect(tokens.tokens[key] == t) }

        let defaultMetrics = DensityTokens.$scoped.withValue(reference) { MetricTunables.metrics.map { $0.value } }
        let defaultText = DensityTokens.$scoped.withValue(reference) { Self.typeSizes() }
        try DensityTokens.$scoped.withValue(tokens) {
            for (metric, base) in zip(MetricTunables.metrics, defaultMetrics)
                where !["sidebarRowHeight", "tabStripHeight"].contains(metric.name) {
                #expect(metric.value == CGFloat(half(Double(base) * t)), "\(preset): \(metric.name)")
            }
            for (size, base) in zip(Self.typeSizes(), defaultText) {
                #expect(abs(size - base * t) < 0.0001)
            }
            #expect(abs(Metrics.chromeRowHeight - row) < 0.0001)
            #expect(abs(SidebarRowTokens.current.listRowHeight - row) < 0.0001)
            #expect(Metrics.space1 == CGFloat(half(2 * t)))
            #expect(abs(Typography.sidebarTitle.pointSize / 14 - t) < 0.0001)
            #expect(Metrics.tabIconSize == CGFloat(half(16.5 * t)))
            let omnibarHeight = try #require(tokens.tokens["omnibarHeight"])
            let omnibarFont = try #require(tokens.tokens["omnibarFontSize"])
            #expect(omnibarHeight == half(29 * omnibarT))
            #expect(abs(omnibarFont / ((10 - 0.31) / 0.70459 / 0.9) - omnibarT) < 0.0001) // Helium's 10 px capitals at Compact
            for key in ["tabIconTitleGap", "sidebarIconGap", "omnibarTextGap"] {
                let value = try #require(tokens.tokens[key])
                let base = try #require(DensityPreset.referenceTokens.tokens[key])
                #expect(value == half(base * factor(key)), "\(preset): \(key)")
            }
        }
    }

    @Test func customGlyphsStillUseTheIconGrid() {
        for level in stride(from: DensityTokens.levelRange.lowerBound, through: DensityTokens.levelRange.upperBound, by: 0.25) {
            let tokens = DensityTokens(id: "custom", name: "Custom", level: level)
            #expect(DensityTokens.iconScale.contains(tokens.resolveGlyph(compact: 14, comfortable: 16)))
        }
    }

    /// A custom density made from a built-in grows its exact title and URL sizes with its own body size: a Default
    /// copy at 20 pt kept 14 pt tab and sidebar titles (review 2026-11-16).
    @Test(arguments: DensityPreset.allCases)
    func aCustomBodySizeScalesTheExactFontTokens(preset: DensityPreset) {
        let base = preset.tokens
        let custom = DensityTokens(id: "big", name: "Big", basedOn: preset.rawValue, level: base.level,
                                   spacing: base.spacing, fontSize: 20, tokens: base.tokens)
        let ratio = 20 / base.bodySize
        #expect(abs(Typography.tabTitleSize(custom) - Typography.tabTitleSize(base) * ratio) < 0.01)
        #expect(abs(Typography.sidebarTitleSize(custom) - Typography.sidebarTitleSize(base) * ratio) < 0.01)
        let omnibar = CGFloat(base.tokens["omnibarFontSize"] ?? 0)
        #expect(abs((custom.fontToken("omnibarFontSize") ?? 0) - omnibar * ratio) < 0.01)
        // The built-in keeps its exact sizes.
        #expect(Typography.tabTitleSize(base) == CGFloat(base.tokens["tabTitleSize"] ?? -1))
    }

    @Test func aCustomFontSizeSetsTheBodyAndKeepsTheRatios() {
        let big = DensityTokens(id: "big-text", name: "Big Text", fontSize: 15)
        DensityTokens.$scoped.withValue(big) {
            #expect(Typography.body.pointSize == 15)
            #expect(abs(Typography.caption.pointSize / Typography.body.pointSize - 10.5 / 12) < 0.05)
            #expect(abs(Typography.header.pointSize / Typography.body.pointSize - 11 / 12) < 0.05)
            #expect(Metrics.sidebarRowHeight == 24, "the font size alone leaves Compact's rows")
        }
    }

    @Test func exactTokensWinOverTheLevel() {
        let custom = DensityTokens(id: "tight", name: "Tight", level: 1, tokens: ["sidebarRowHeight": 22, "itemCornerRadius": 4])
        DensityTokens.$scoped.withValue(custom) {
            #expect(Metrics.sidebarRowHeight == 22)
            #expect(Metrics.itemCornerRadius == 4)
            #expect(MetricTunables.tabHeight.value == MetricTunables.tabHeight.comfortable, "other tokens follow the level")
        }
    }

    @Test func spacingScalesPaddingInHalfPoints() {
        let roomy = DensityTokens(id: "roomy", name: "Roomy", spacing: 1.25)
        DensityTokens.$scoped.withValue(roomy) {
            #expect(Metrics.space4 == (ChromeTunables.space4.value * 1.25 * 2).rounded() / 2)
            #expect(Metrics.space4 > ChromeTunables.space4.value)
        }
    }

    @Test func valuesAreClamped() {
        let wild = DensityTokens(id: "wild", name: "Wild", level: 40, spacing: -3, fontSize: 200, tokens: ["iconSize": -1])
        #expect(wild.level == DensityTokens.levelRange.upperBound)
        #expect(wild.spacing == DensityTokens.spacingRange.lowerBound)
        #expect(wild.fontSize == DensityTokens.fontSizeRange.upperBound)
        #expect(wild.tokens.isEmpty, "a negative token is dropped")
    }

    @Test func familyFollowsTheLevel() {
        #expect(DensityPreset.ultraCompact.tokens.family == .compact)
        #expect(DensityPreset.compact.tokens.family == .compact)
        #expect(DensityPreset.cozy.tokens.family == .comfortable)
        #expect(DensityPreset.spacious.tokens.family == .comfortable)
        let design = DesignSettings()
        design.density = .comfortable
        #expect(design.densityTokens == DensityPreset.comfortable.tokens)
    }
}
