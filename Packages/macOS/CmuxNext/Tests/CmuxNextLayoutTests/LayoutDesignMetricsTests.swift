import AppKit
import CmuxNextDesign
import Observation
import Testing
@testable import CmuxNextLayout

/// Mutates `DesignSettings.shared`, so the suite runs serially and restores it.
@MainActor
@Suite(.serialized) struct LayoutDesignMetricsTests {
    private let layout = ScreenLayout.columns([
        LayoutColumn(id: "c1", width: 0.5, root: .leaf("a")),
        LayoutColumn(id: "c2", width: 0.5, root: .leaf("b")),
    ])
    private let viewport = CGSize(width: 1000, height: 400)

    private func withColumnGap<T>(_ gap: CGFloat?, _ body: () async throws -> T) async rethrows -> T {
        let previous = DesignSettings.shared.overrides[.columnGap]
        DesignSettings.shared.setOverride(.columnGap, gap)
        defer { DesignSettings.shared.setOverride(.columnGap, previous) }
        return try await body()
    }

    @Test func columnGapOverrideChangesComputedColumnFrames() async {
        let model = LayoutModel()
        let narrow = await withColumnGap(2) { ScreenGeometry.compute(layout, viewport: viewport, style: model.style) }
        let wide = await withColumnGap(20) { ScreenGeometry.compute(layout, viewport: viewport, style: model.style) }

        #expect(narrow.columns["c1"]?.minX == 2)
        #expect(wide.columns["c1"]?.minX == 20)
        #expect(narrow.columns["c2"]?.minX != wide.columns["c2"]?.minX)
        #expect((wide.columns["c1"]?.width ?? 0) < (narrow.columns["c1"]?.width ?? 0))
    }

    @Test func pinnedBaseStyleIgnoresDesignMetrics() async {
        let model = LayoutModel()
        model.followsDesignMetrics = false
        model.baseStyle.columnGap = 8
        let gap = await withColumnGap(20) { model.style.columnGap }
        #expect(gap == 8)
    }

    @Test func styleIsObservationTrackedOnDesignSettings() async {
        let model = LayoutModel()
        // onChange runs synchronously inside the setter below, on this actor.
        nonisolated final class Flag: @unchecked Sendable { var fired = false }
        let flag = Flag()
        await withColumnGap(nil) {
            withObservationTracking {
                _ = model.style
            } onChange: {
                flag.fired = true
            }
            DesignSettings.shared.setOverride(.columnGap, 14)
        }
        #expect(flag.fired)
    }

    @Test func rootViewRelayoutsLiveWhenColumnGapChanges() async throws {
        let model = LayoutModel(screens: [LayoutScreen(id: "s", name: "", layout: layout)], activeScreenID: "s", focusedPane: "a")
        let provider = StubProvider()
        let view = LayoutRootView(model: model, contentProvider: provider)
        view.frame = CGRect(origin: .zero, size: viewport)
        view.layoutSubtreeIfNeeded()

        try await withColumnGap(4) {
            try await waitUntil { view.frame(of: "a")?.minX == 4 }
            DesignSettings.shared.setOverride(.columnGap, 18)
            try await waitUntil { view.frame(of: "a")?.minX == 18 }
            #expect(view.frame(of: "b")?.minX == 18 + (viewport.width - 18 * 3) / 2 + 18)
        }
        withExtendedLifetime(provider) {}
    }

    /// Yields to the main actor until `condition` holds; the view applies
    /// model changes from an `Observations` task.
    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<1000 where !condition() {
            await Task.yield()
        }
        #expect(condition())
    }
}

private final class StubProvider: LayoutPaneContentProvider {
    func makeContentView(for pane: PaneID) -> NSView { NSView() }
}
