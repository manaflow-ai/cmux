import CoreGraphics
import CmuxMobileShellModel
import Testing
@testable import CmuxMobileShellUI

@Suite struct PaneMapCollectionLayoutEngineTests {
    private let engine = PaneMapCollectionLayoutEngine()

    @Test func undersizedSiblingBorrowsSpaceFromTheLargerPane() throws {
        let layout = horizontalLayout(ratio: 0.95, paneIDs: ["large", "small"])

        let result = engine.layout(layout, in: CGSize(width: 390, height: 700))
        let large = try #require(result.framesByPaneID["large"])
        let small = try #require(result.framesByPaneID["small"])

        #expect(!result.overflowsHorizontally)
        #expect(large.width >= 156)
        #expect(small.width >= 156)
        #expect(small.minX - large.maxX == 14)
        #expect(small.width == 156)
    }

    @Test func impossibleMinimumWidthsProduceHorizontalOverflow() throws {
        let layout = horizontalLayout(
            ratio: 0.5,
            paneIDs: ["one", "two", "three"]
        )

        let result = engine.layout(layout, in: CGSize(width: 390, height: 700))

        #expect(result.overflowsHorizontally)
        #expect(!result.overflowsVertically)
        #expect(result.contentSize.width == 528)
        for paneID in ["one", "two", "three"] {
            #expect(try #require(result.framesByPaneID[paneID]).width >= 156)
        }
    }

    @Test func fourPaneGridPreservesMacRatiosWhenMinimumsFit() throws {
        let layout = fourPaneLayout()

        let result = engine.layout(layout, in: CGSize(width: 1_000, height: 800))
        let topLeft = try #require(result.framesByPaneID["top-left"])
        let bottomLeft = try #require(result.framesByPaneID["bottom-left"])
        let topRight = try #require(result.framesByPaneID["top-right"])
        let bottomRight = try #require(result.framesByPaneID["bottom-right"])

        #expect(!result.overflowsHorizontally)
        #expect(!result.overflowsVertically)
        #expect(topLeft.width > topRight.width)
        #expect(topLeft.height < bottomLeft.height)
        #expect(topRight.height > bottomRight.height)
        #expect(abs(topLeft.width / (topLeft.width + topRight.width) - 0.6) < 0.01)
        #expect(abs(topLeft.height / (topLeft.height + bottomLeft.height) - 0.35) < 0.01)
        #expect(abs(topRight.height / (topRight.height + bottomRight.height) - 0.65) < 0.01)
    }

    private func horizontalLayout(ratio: Double, paneIDs: [String]) -> MobilePaneLayout {
        precondition(paneIDs.count >= 2)
        var node = MobilePaneLayout.Node.pane(pane(paneIDs.last!))
        for paneID in paneIDs.dropLast().reversed() {
            node = .split(MobilePaneSplit(
                id: "split-\(paneID)",
                orientation: .horizontal,
                ratio: ratio,
                first: .pane(pane(paneID)),
                second: node
            ))
        }
        return MobilePaneLayout(version: 1, focusedPaneID: nil, root: node)
    }

    private func fourPaneLayout() -> MobilePaneLayout {
        MobilePaneLayout(
            version: 1,
            focusedPaneID: "top-left",
            root: .split(MobilePaneSplit(
                id: "root",
                orientation: .horizontal,
                ratio: 0.6,
                first: .split(MobilePaneSplit(
                    id: "left",
                    orientation: .vertical,
                    ratio: 0.35,
                    first: .pane(pane("top-left")),
                    second: .pane(pane("bottom-left"))
                )),
                second: .split(MobilePaneSplit(
                    id: "right",
                    orientation: .vertical,
                    ratio: 0.65,
                    first: .pane(pane("top-right")),
                    second: .pane(pane("bottom-right"))
                ))
            ))
        )
    }

    private func pane(_ id: String) -> MobilePaneNode {
        MobilePaneNode(id: id, selectedSurfaceID: nil, surfaces: [])
    }
}
