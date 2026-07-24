import Foundation
import Testing

@testable import CmuxMobileShellModel

@Suite struct MobilePaneLayoutTests {
    @Test func singlePaneOccupiesFullUnitRect() throws {
        let layout = MobilePaneLayout(
            version: 1,
            focusedPaneID: "pane-a",
            root: .pane(pane("pane-a"))
        )

        let rect = try #require(layout.normalizedRects()["pane-a"])
        #expect(rect == CGRect(x: 0, y: 0, width: 1, height: 1))
    }

    @Test func horizontalSplitUsesRatioForFirstPaneWidth() throws {
        let layout = MobilePaneLayout(
            version: 2,
            focusedPaneID: nil,
            root: .split(MobilePaneSplit(
                id: "split-root",
                orientation: .horizontal,
                ratio: 0.3,
                first: .pane(pane("pane-a")),
                second: .pane(pane("pane-b"))
            ))
        )
        let rects = layout.normalizedRects()

        #expect(try #require(rects["pane-a"]) == CGRect(x: 0, y: 0, width: 0.3, height: 1))
        #expect(try #require(rects["pane-b"]) == CGRect(x: 0.3, y: 0, width: 0.7, height: 1))
    }

    @Test func nestedHorizontalAndVerticalSplitsComposeUnitRects() throws {
        let layout = MobilePaneLayout(
            version: 3,
            focusedPaneID: "pane-c",
            root: .split(MobilePaneSplit(
                id: "split-horizontal",
                orientation: .horizontal,
                ratio: 0.5,
                first: .pane(pane("pane-a")),
                second: .split(MobilePaneSplit(
                    id: "split-vertical",
                    orientation: .vertical,
                    ratio: 0.25,
                    first: .pane(pane("pane-b")),
                    second: .pane(pane("pane-c"))
                ))
            ))
        )
        let rects = layout.normalizedRects()

        #expect(try #require(rects["pane-a"]) == CGRect(x: 0, y: 0, width: 0.5, height: 1))
        #expect(try #require(rects["pane-b"]) == CGRect(x: 0.5, y: 0, width: 0.5, height: 0.25))
        #expect(try #require(rects["pane-c"]) == CGRect(x: 0.5, y: 0.25, width: 0.5, height: 0.75))
    }

    @Test func splitInitializerEnforcesFiniteDisplayableRatios() {
        #expect(split(ratio: -1).ratio == 0.05)
        #expect(split(ratio: 0.01).ratio == 0.05)
        #expect(split(ratio: 0.25).ratio == 0.25)
        #expect(split(ratio: 0.99).ratio == 0.95)
        #expect(split(ratio: 2).ratio == 0.95)
        #expect(split(ratio: .nan).ratio == 0.5)
        #expect(split(ratio: .infinity).ratio == 0.5)
        #expect(split(ratio: -.infinity).ratio == 0.5)
    }

    @Test func paneLookupAndOrderedPanesFollowDepthFirstOrder() {
        let firstPane = pane(
            "pane-a",
            surfaces: [surface("surface-a", type: .terminal)]
        )
        let secondPane = pane(
            "pane-b",
            surfaces: [
                surface("surface-b", type: .browser),
                surface("surface-c", type: .markdown),
            ]
        )
        let thirdPane = pane(
            "pane-c",
            surfaces: [surface("surface-d", type: .other("future"))]
        )
        let layout = MobilePaneLayout(
            version: 4,
            focusedPaneID: "pane-b",
            root: .split(MobilePaneSplit(
                id: "split-root",
                orientation: .horizontal,
                ratio: 0.5,
                first: .split(MobilePaneSplit(
                    id: "split-nested",
                    orientation: .vertical,
                    ratio: 0.5,
                    first: .pane(firstPane),
                    second: .pane(secondPane)
                )),
                second: .pane(thirdPane)
            ))
        )

        #expect(layout.orderedPanes.map(\.id) == ["pane-a", "pane-b", "pane-c"])
        #expect(layout.pane(containing: "surface-c") == secondPane)
        #expect(layout.pane(containing: "missing") == nil)
        #expect(firstPane.surfaces[0].type.isTerminal)
        #expect(!secondPane.surfaces[0].type.isTerminal)
    }

    private func pane(
        _ id: String,
        surfaces: [MobilePaneSurface] = []
    ) -> MobilePaneNode {
        MobilePaneNode(id: id, selectedSurfaceID: surfaces.first?.id, surfaces: surfaces)
    }

    private func split(ratio: Double) -> MobilePaneSplit {
        MobilePaneSplit(
            id: "split",
            orientation: .horizontal,
            ratio: ratio,
            first: .pane(pane("pane-a")),
            second: .pane(pane("pane-b"))
        )
    }

    private func surface(
        _ id: String,
        type: MobilePaneSurfaceType
    ) -> MobilePaneSurface {
        MobilePaneSurface(id: id, type: type, title: id)
    }
}
