import AppKit
@testable import CmuxNextDesign
import Testing

/// Density from first principles (Lawrence 2026-10-20: "we need more options, and for font size
/// to scale with it as well, i really like how compact looks today though so let's not mess with
/// that"). plans/cmux-next/density-DESIGN.md.
///
/// Every test draws through `DensityTokens.$scoped`, so it never changes the app-wide
/// `DesignSettings.shared` other suites read in parallel.
@MainActor @Suite struct DensityTokensTests {
    /// Compact's chrome before the density rework, value by value: the guard that keeps today's
    /// Compact look pixel-identical. Change a number here only with Lawrence's OK.
    private static let compactMetrics: [(String, CGFloat)] = [
        ("sidebarWidth", 208), ("titlebarHeight", 32), ("sidebarRowHeight", 24), ("sidebarRowHeightWithSubtitle", 36),
        ("sidebarHeaderHeight", 22), ("roomDotDiameter", 8), ("roomDotSlot", 24), ("tabHeight", 24), ("controlHeight", 24),
        ("tabMaxWidth", 200), ("tabMinWidth", 32), ("paletteRowHeight", 28), ("paletteSearchHeight", 44), ("paletteWidth", 640),
        ("panelInset", 6), ("columnGap", 6), ("densityPaneCornerRadius", 6), ("panelCornerRadius", 10), ("itemCornerRadius", 6),
        ("iconSize", 14), ("smallIconSize", 12), ("scrollEdgeFade", 18),
    ]

    private static func live(_ name: String) -> CGFloat? {
        MetricTunables.metrics.first { $0.name == name }?.value
    }

    private static func typeSizes() -> [CGFloat] {
        [Typography.body, Typography.bodyEmphasized, Typography.caption, Typography.header, Typography.search,
         Typography.shortcut, Typography.title, Typography.subtitle].map(\.pointSize)
    }

    @Test func compactIsExactlyTodaysCompact() throws {
        try DensityTokens.$scoped.withValue(DensityPreset.compact.tokens) {
            for (name, expected) in Self.compactMetrics {
                let value = try #require(Self.live(name), "no metric \(name)")
                #expect(value == expected, "\(name) at Compact is \(value), was \(expected)")
            }
            #expect(Metrics.tabStripHeight == (Metrics.compactTabs ? 26 : 28))
            #expect(Self.typeSizes() == [12, 12, 10.5, 11, 16, 10.5, 20, 13])
            #expect(Metrics.codePanePadding == 2)
            #expect(Metrics.space1 == ChromeTunables.space1.value && Metrics.space3 == ChromeTunables.space3.value
                && Metrics.space6 == ChromeTunables.space6.value, "Compact keeps every padding step")
            #expect(Metrics.density == .compact)
        }
    }

    @Test func theDefaultDensityIsCompact() {
        #expect(DesignSettings().densityTokens == DensityPreset.compact.tokens)
        #expect(DensityPreset.compact.tokens.level == 0 && DensityPreset.compact.tokens.spacing == 1)
        #expect(DensityPreset.compact.tokens.tokens.isEmpty && DensityPreset.compact.tokens.fontSize == nil)
    }

    @Test func comfortableIsTodaysComfortable() {
        DensityTokens.$scoped.withValue(DensityPreset.comfortable.tokens) {
            for metric in MetricTunables.metrics {
                #expect(metric.value == metric.comfortable, "\(metric.name) at Comfortable")
            }
            #expect(Self.typeSizes() == [13, 13, 11, 12, 18, 11, 22, 14])
        }
    }

    @Test func fiveBuiltInsDensestFirst() {
        #expect(DensityPreset.allCases.map(\.rawValue) == ["ultraCompact", "compact", "cozy", "comfortable", "spacious"])
        let levels = DensityPreset.allCases.map(\.tokens.level)
        #expect(levels == levels.sorted() && Set(levels).count == levels.count)
    }

    @Test func textAndRowsGrowWithDensity() {
        var bodies: [CGFloat] = [], rows: [CGFloat] = [], tabs: [CGFloat] = [], radii: [CGFloat] = []
        for preset in DensityPreset.allCases {
            DensityTokens.$scoped.withValue(preset.tokens) {
                bodies.append(Typography.body.pointSize)
                rows.append(Metrics.sidebarRowHeight)
                tabs.append(MetricTunables.tabHeight.value)
                radii.append(Metrics.itemCornerRadius)
            }
        }
        for series in [bodies, rows, tabs] {
            #expect(zip(series, series.dropFirst()).allSatisfy { $0 < $1 }, "strictly larger at each step: \(series)")
        }
        #expect(zip(radii, radii.dropFirst()).allSatisfy { $0 <= $1 }, "corner radii never shrink: \(radii)")
        #expect(bodies == [11.5, 12, 12.5, 13, 14])
        #expect(rows == [20, 24, 28, 32, 38])
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
