import CoreGraphics
@testable import CmuxNextDesign
import CmuxNextDesignTokens
import Testing

/// Settings-derived metric getters must never read each other in a loop under any combination of
/// settings. A profile setting both `appearance.metrics.tabStripHeight` (26) and
/// `layout.cornerPadding` (4) crashed the app on apply (2026-11-16, stack overflow on the main
/// thread): `Metrics.tabStripHeight` derived the strip from `Metrics.tabHeight` under a corner
/// padding, and `Metrics.tabHeight` derived the pill from `Metrics.tabStripHeight` under a set strip.
@MainActor @Suite(.serialized) struct MetricsCycleTests {
    /// Runs `body` with these settings in the process-wide design settings, then restores them.
    func with(strip: CGFloat?, cornerPadding: CGFloat?, panePadding: CGFloat? = nil, sidebarRow: CGFloat? = nil,
              _ body: () throws -> Void) rethrows {
        let design = DesignSettings.shared
        let before = (design.overrides[.tabStripHeight], design.overrides[.sidebarRowHeight], design.paneChrome)
        defer {
            design.setOverride(.tabStripHeight, before.0)
            design.setOverride(.sidebarRowHeight, before.1)
            design.setPaneChrome(before.2)
        }
        design.setOverride(.tabStripHeight, strip)
        design.setOverride(.sidebarRowHeight, sidebarRow)
        var chrome = before.2
        chrome.cornerPadding = cornerPadding
        chrome.padding = panePadding
        design.setPaneChrome(chrome)
        try body()
    }

    /// Every getter on the crash's path and its neighbors, read once. A cycle overflows the stack here.
    func readEveryChromeMetric() -> [CGFloat] {
        let pane = PaneChromeMetrics.current
        let row = SidebarRowTokens.current
        return [Metrics.tabHeight, Metrics.tabStripHeight, Metrics.chromeRowHeight, pane.stripHeight, pane.tabHeight,
                pane.pillTop(scale: 2), Metrics.tabStripCardInset, Metrics.cornerPadding, Metrics.corners.outer,
                Metrics.surfaceCornerRadius, Metrics.panelCornerRadius, Metrics.paneCornerRadius,
                Metrics.floatingPaneCornerRadius, Metrics.paneChromeInset, Metrics.firstTabIconLeading,
                Metrics.tabIconEvenLeadingInset, Metrics.itemCornerRadius, Metrics.controlCornerRadius,
                Metrics.tabCornerRadius, Metrics.browserRowGap ?? 0, row.rowHeight, row.base.cornerRadius]
    }

    /// The crash: both set, read the tab, the strip and the pane chrome.
    @Test func aSetStripAndCornerPaddingResolve() {
        // Compact, where 26 - 2 * 4 leaves the pill above its icon floor.
        DensityTokens.$scoped.withValue(DensityPreset.compact.tokens) { with(strip: 26, cornerPadding: 4) {
            let strip = Metrics.tabStripHeight
            let tab = Metrics.tabHeight
            let pane = PaneChromeMetrics.current
            // The set bar keeps its height; the pill fills it inside the padding above and below.
            #expect(strip == MetricTunables.tabStripHeight.value)
            #expect(tab == strip - 2 * Metrics.scale(4) - Metrics.stripTopOutset)
            #expect(pane.stripHeight == strip && pane.tabHeight == tab)
            #expect(tab > 0)
            #expect(Metrics.panelCornerRadius >= 0)
        } }
    }

    /// Corner padding alone still derives the strip from the tab, and a set strip alone still sizes the pill.
    @Test func eachSettingAloneKeepsItsRule() {
        with(strip: nil, cornerPadding: 4) {
            #expect(Metrics.tabStripHeight == Metrics.tabHeight + 2 * Metrics.scale(4) + Metrics.stripTopOutset)
        }
        with(strip: 40, cornerPadding: nil) {
            #expect(Metrics.tabStripHeight == MetricTunables.tabStripHeight.value)
            #expect(Metrics.tabHeight > 0)
        }
    }

    /// A strip set in Debug Settings counts as set too: with a corner padding it keeps its height and
    /// the pill fits inside it, and the tab and strip still resolve without reading each other.
    @Test func aDebugSettingsStripWithCornerPaddingResolves() {
        let store = TunableStore.shared
        let key = MetricTunables.tabStripHeight.tunable.key
        store.activate(file: nil)
        store.register(MetricTunables.metrics.map(\.descriptor))
        let before = store.override(key)
        defer { store.set(key, before) }
        store.set(key, .number(30))
        DensityTokens.$scoped.withValue(DensityPreset.compact.tokens) { with(strip: nil, cornerPadding: 4) {
            #expect(Metrics.tabStripIsSet)
            #expect(Metrics.tabStripHeight == MetricTunables.tabStripHeight.value)
            #expect(Metrics.tabHeight == Metrics.tabStripHeight - 2 * Metrics.scale(4) - Metrics.stripTopOutset)
            let finite = readEveryChromeMetric().allSatisfy { $0.isFinite }
            #expect(finite)
        } }
    }

    /// The class: every density with every combination of the settings these getters branch on.
    @Test func noCombinationOfSettingsRecurses() {
        for preset in DensityPreset.allCases {
            DensityTokens.$scoped.withValue(preset.tokens) {
                for strip in [nil, 22, 26, 44] as [CGFloat?] {
                    for cornerPadding in [nil, 0, 4, 12] as [CGFloat?] {
                        for panePadding in [nil, 0, 6] as [CGFloat?] {
                            for sidebarRow in [nil, 30] as [CGFloat?] {
                                with(strip: strip, cornerPadding: cornerPadding, panePadding: panePadding, sidebarRow: sidebarRow) {
                                    let finite = readEveryChromeMetric().allSatisfy { $0.isFinite }
                                    #expect(finite,
                                            "\(preset) strip \(String(describing: strip)) corner \(String(describing: cornerPadding))")
                                    #expect(Metrics.tabHeight >= 0)
                                    if strip != nil, cornerPadding != nil {
                                        // The padding gives way before the pill shrinks under its icon.
                                        #expect(Metrics.tabHeight >= min(Metrics.iconSize, Metrics.tabStripHeight - Metrics.stripTopOutset))
                                        #expect(Metrics.tabHeight <= Metrics.tabStripHeight - Metrics.stripTopOutset)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
