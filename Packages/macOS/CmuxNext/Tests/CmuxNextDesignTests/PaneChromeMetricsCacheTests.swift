import AppKit
@testable import CmuxNextDesign
import CmuxNextDesignTokens
import Observation
import Testing

/// `PaneChromeMetrics.current` is cached on its inputs (`PaneChromeMetrics+Cache`): about 21% of a live resize's
/// `ShellWindow.setFrame` re-derived it on every read (other Mac samples, 2026-11-24). The cache must never serve a value
/// a fresh derivation would not give, and a read answered from it must still register the Observation dependency a view
/// laid out with it relies on to lay out again when a setting changes.
@MainActor @Suite(.serialized) struct PaneChromeMetricsCacheTests {
    // Nonisolated: onChange runs outside the main actor (this target is main-actor by default).
    private nonisolated final class Flag: @unchecked Sendable { var raised = false }

    private func restore(_ settings: DesignSettings, density: DensityTokens, chrome: PaneChromeOverrides,
                         position: TabBarPosition, override: CGFloat?) {
        settings.densityTokens = density
        settings.setPaneChrome(chrome)
        settings.tabBarPosition = position
        settings.setOverride(.tabStripHeight, override)
    }

    @Test func theCachedValueIsAFreshDerivationAfterEveryKindOfChange() {
        let settings = DesignSettings.shared
        let density = settings.densityTokens, chrome = settings.paneChrome, position = settings.tabBarPosition
        let override = settings.overrides[.tabStripHeight]
        defer { restore(settings, density: density, chrome: chrome, position: position, override: override) }

        let changes: [(String, () -> Void)] = [
            ("density", { settings.densityTokens = DensityPreset.comfortable.tokens }),
            ("density back", { settings.densityTokens = .compact }),
            ("strip override", { settings.setOverride(.tabStripHeight, 40) }),
            ("pane padding", { var c = settings.paneChrome; c.padding = 9; settings.setPaneChrome(c) }),
            ("corner padding", { var c = settings.paneChrome; c.cornerPadding = 3; settings.setPaneChrome(c) }),
            ("tab bar position", { settings.tabBarPosition = .bottom }),
            ("override cleared", { settings.setOverride(.tabStripHeight, nil) }),
        ]
        for (name, change) in changes {
            change()
            #expect(PaneChromeMetrics.current == PaneChromeMetrics.derived, "after \(name) the cache served a stale value")
            // Read again: a hit, still the fresh value.
            #expect(PaneChromeMetrics.current == PaneChromeMetrics.derived, "a second read after \(name) differs")
        }
        // A scoped density (a preview drawing at another density) is an input too.
        DensityTokens.$scoped.withValue(DensityPreset.comfortable.tokens) {
            #expect(PaneChromeMetrics.current == PaneChromeMetrics.derived, "a preview's density was served the app's value")
        }
        #expect(PaneChromeMetrics.current == PaneChromeMetrics.derived, "after the preview the app's value came back")
    }

    @Test func repeatedReadsWithNoChangeDeriveOnce() {
        _ = PaneChromeMetrics.current
        let derivations = PaneChromeMetrics.derivations
        for _ in 0..<50 { _ = PaneChromeMetrics.current }
        #expect(PaneChromeMetrics.derivations == derivations, "a read with unchanged inputs derived again")
    }

    @Test func aCachedReadStillTracksADensityChange() {
        let settings = DesignSettings.shared
        let density = settings.densityTokens
        defer { settings.densityTokens = density }
        _ = PaneChromeMetrics.current  // the next read is a hit
        let changed = Flag()
        withObservationTracking { _ = PaneChromeMetrics.current } onChange: { changed.raised = true }
        settings.densityTokens = density == .compact ? DensityPreset.comfortable.tokens : .compact
        #expect(changed.raised, "a view that read the cached metrics would not lay out again on a density change")
    }
}
