import AppKit
@testable import CmuxNextBrowser
import CmuxNextDesign
import Testing

/// `OmnibarMetrics.current` is read many times in every layout of the omnibar and its toolbar (each size, the font):
/// rebuilt from the design tokens at each read, it cost about 0.4 ms of each window resize step (2026-11-27 sample of a
/// corner drag, bench12). It changes only with the density, the size overrides and the tunables, so it is built once
/// and kept until one of them changes.
@MainActor @Suite(.serialized) struct OmnibarMetricsKeptTests {
    /// Lets the main queue run, so an earlier change's settling window closes (`TokenMemo`).
    private func mainTurn() async {
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
    }

    @Test func readsWithNothingChangedBuildTheMetricsOnce() async {
        await mainTurn()
        let first = OmnibarMetrics.current
        let appearance = OmnibarGlassAppearance.shared, before = appearance.metricsBuilds
        for _ in 0..<50 { #expect(OmnibarMetrics.current == first) }
        #expect(appearance.metricsBuilds == before, "50 reads with nothing changed built the metrics \(appearance.metricsBuilds - before) times")
    }

    /// A scoped appearance (previews, tests) is read as it is, and never kept for the app's own reads.
    @Test func aScopedAppearanceIsReadFreshAndNotKept() async {
        await mainTurn()
        let unscoped = OmnibarMetrics.current
        let overrides = OmnibarGlassAppearance()
        overrides.applySize(height: unscoped.barHeight + 8, fontSize: unscoped.fontSize + 2)
        OmnibarGlassAppearance.$scoped.withValue(overrides) {
            #expect(OmnibarMetrics.current.barHeight == unscoped.barHeight + 8)
            #expect(OmnibarMetrics.current.fontSize == unscoped.fontSize + 2)
        }
        #expect(OmnibarMetrics.current == unscoped, "a scoped appearance's metrics were kept for the app's reads")
    }
}
