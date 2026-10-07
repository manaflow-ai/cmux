import AppKit
import CmuxNextDesign
import Testing
@testable import CmuxNextLayout

/// Rects the layout reports to Chromium pages as occlusion holes
/// (`interactiveOverlayRects`, masked out of the page). A divider's hit area
/// is wider than its line and reaches into the panes next to it; it must not
/// cut the page, or a band of the page disappears on each side of every
/// divider at 0 padding. Part of the serialized suite (it mutates
/// `DesignSettings.shared`).
extension LayoutDesignMetricsTests {
    private func grid() -> LayoutModel {
        let root = SplitNode.split(
            "root", axis: .horizontal, ratio: 0.5,
            a: .split("left", axis: .vertical, ratio: 0.5, a: .leaf("tl"), b: .leaf("bl")),
            b: .split("right", axis: .vertical, ratio: 0.5, a: .leaf("tr"), b: .leaf("br"))
        )
        return LayoutModel(screens: [LayoutScreen(id: "s", name: "", layout: .splits(root))], activeScreenID: "s", focusedPane: "tl")
    }

    private func contentRects(_ view: LayoutRootView) -> [CGRect] {
        ["tl", "tr", "bl", "br"].compactMap { pane in
            view.context.hosts[PaneID(pane)].map { view.convert($0.contentRect, from: $0) }
        }
    }

    @Test func dividerHitAreasDoNotCutPagesAtZeroPadding() async throws {
        let provider = StubProvider()
        let view = LayoutRootView(model: grid(), contentProvider: provider)
        view.frame = CGRect(origin: .zero, size: viewport)
        try await withPaneChrome(PaneChromeOverrides(padding: 0, border: PaneBorderStyle.none)) {
            view.layoutSubtreeIfNeeded()
            try await waitUntil { view.context.hosts["br"].map { $0.contentRect == $0.bounds } ?? false }
            let contents = contentRects(view)
            #expect(contents.count == 4)
            for hole in view.interactiveOverlayRects {
                for content in contents {
                    let overlap = hole.intersection(content)
                    #expect(overlap.isNull || overlap.width < 0.01 || overlap.height < 0.01,
                            "occlusion \(hole) cuts pane content \(content)")
                }
            }
            // Each divider's drawn line (between the panes) stays uncovered.
            #expect(view.interactiveOverlayRects.count == 3)
            #expect(view.interactiveOverlayRects.allSatisfy { min($0.width, $0.height) <= view.context.style.dividerThickness + 0.01 })
            // The hit areas still take the mouse: they are reported as
            // mouse areas (click-catching panels above pages), one per
            // divider, each reaching into both neighboring panes.
            let areas = view.dividerMouseAreas
            #expect(Set(areas.map(\.id)) == ["split:root", "split:left", "split:right"])
            let root = try #require(areas.first { $0.id == "split:root" })
            #expect(root.resizesColumns)
            #expect(root.rect.width >= view.context.style.dividerHitThickness)
            #expect(contents.contains { $0.intersects(root.rect) && $0.maxX > root.rect.minX && $0.minX < root.rect.minX })
            #expect(areas.first { $0.id == "split:left" }?.resizesColumns == false)
        }
        withExtendedLifetime(provider) {}
    }
}
