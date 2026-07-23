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

    @Test func undersizedVerticalSiblingBorrowsSpaceFromTheLargerPane() throws {
        let layout = verticalLayout(ratio: 0.95, paneIDs: ["large", "small"])

        let result = engine.layout(layout, in: CGSize(width: 390, height: 520))
        let large = try #require(result.framesByPaneID["large"])
        let small = try #require(result.framesByPaneID["small"])

        #expect(!result.overflowsVertically)
        #expect(large.height >= 220)
        #expect(small.height == 220)
        #expect(small.minY - large.maxY == 14)
    }

    @Test func impossibleMinimumHeightsProduceVerticalOverflow() throws {
        let layout = verticalLayout(
            ratio: 0.5,
            paneIDs: ["one", "two", "three"]
        )

        let result = engine.layout(layout, in: CGSize(width: 390, height: 520))

        #expect(!result.overflowsHorizontally)
        #expect(result.overflowsVertically)
        #expect(result.contentSize.height == 712)
        for paneID in ["one", "two", "three"] {
            #expect(try #require(result.framesByPaneID[paneID]).height >= 220)
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

    private func verticalLayout(ratio: Double, paneIDs: [String]) -> MobilePaneLayout {
        precondition(paneIDs.count >= 2)
        var node = MobilePaneLayout.Node.pane(pane(paneIDs.last!))
        for paneID in paneIDs.dropLast().reversed() {
            node = .split(MobilePaneSplit(
                id: "split-\(paneID)",
                orientation: .vertical,
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

@Suite struct PaneMapInteractiveZoomGeometryTests {
    private let initialFrame = CGRect(x: 100, y: 200, width: 120, height: 240)
    private let targetFrame = CGRect(x: 0, y: 0, width: 390, height: 844)
    private let anchor = CGPoint(x: 0.25, y: 0.75)

    @Test func zeroProgressPreservesTheSourceFrame() {
        let sourceAnchor = CGPoint(
            x: initialFrame.minX + initialFrame.width * anchor.x,
            y: initialFrame.minY + initialFrame.height * anchor.y
        )

        let frame = PaneMapInteractiveZoomGeometry.frame(
            initialFrame: initialFrame,
            targetFrame: targetFrame,
            normalizedAnchor: anchor,
            gestureLocation: sourceAnchor,
            progress: 0
        )

        #expect(frame == initialFrame)
    }

    @Test func intermediateProgressTracksTheGestureCenter() {
        let progress: CGFloat = 0.4
        let gestureLocation = CGPoint(x: 250, y: 500)

        let frame = PaneMapInteractiveZoomGeometry.frame(
            initialFrame: initialFrame,
            targetFrame: targetFrame,
            normalizedAnchor: anchor,
            gestureLocation: gestureLocation,
            progress: progress
        )

        let renderedAnchor = CGPoint(
            x: frame.minX + frame.width * anchor.x,
            y: frame.minY + frame.height * anchor.y
        )

        #expect(abs(frame.width - 228) < 0.001)
        #expect(abs(frame.height - 481.6) < 0.001)
        #expect(abs(renderedAnchor.x - gestureLocation.x) < 0.001)
        #expect(abs(renderedAnchor.y - gestureLocation.y) < 0.001)
    }

    @Test func movingTheGestureCenterMovesTheFrameOneForOne() {
        let first = PaneMapInteractiveZoomGeometry.frame(
            initialFrame: initialFrame,
            targetFrame: targetFrame,
            normalizedAnchor: anchor,
            gestureLocation: CGPoint(x: 200, y: 400),
            progress: 0.5
        )
        let second = PaneMapInteractiveZoomGeometry.frame(
            initialFrame: initialFrame,
            targetFrame: targetFrame,
            normalizedAnchor: anchor,
            gestureLocation: CGPoint(x: 237, y: 381),
            progress: 0.5
        )

        #expect(abs(second.minX - first.minX - 37) < 0.001)
        #expect(abs(second.minY - first.minY + 19) < 0.001)
        #expect(second.size == first.size)
    }

    @Test func settlementUsesExactSourceAndTargetFrames() {
        let source = PaneMapInteractiveZoomGeometry.settledFrame(
            from: initialFrame,
            to: targetFrame,
            progress: 0
        )
        let target = PaneMapInteractiveZoomGeometry.settledFrame(
            from: initialFrame,
            to: targetFrame,
            progress: 1
        )

        #expect(source == initialFrame)
        #expect(target == targetFrame)
    }

    @Test func pinchScaleProgressIsAbsoluteAndClamped() {
        #expect(PaneMapInteractiveZoomGeometry.progress(forPinchScale: 0.5) == 0)
        #expect(PaneMapInteractiveZoomGeometry.progress(forPinchScale: 1) == 0)
        #expect(abs(
            PaneMapInteractiveZoomGeometry.progress(forPinchScale: 1.575) - 0.5
        ) < 0.001)
        #expect(PaneMapInteractiveZoomGeometry.progress(forPinchScale: 2.15) == 1)
        #expect(PaneMapInteractiveZoomGeometry.progress(forPinchScale: 4) == 1)
    }

    @Test func reversingScaleDoesNotAccumulateGeometry() {
        let sourceAnchor = CGPoint(
            x: initialFrame.minX + initialFrame.width * anchor.x,
            y: initialFrame.minY + initialFrame.height * anchor.y
        )
        let expanded = PaneMapInteractiveZoomGeometry.frame(
            initialFrame: initialFrame,
            targetFrame: targetFrame,
            normalizedAnchor: anchor,
            gestureLocation: sourceAnchor,
            progress: 0.7
        )
        let reversed = PaneMapInteractiveZoomGeometry.frame(
            initialFrame: initialFrame,
            targetFrame: targetFrame,
            normalizedAnchor: anchor,
            gestureLocation: sourceAnchor,
            progress: 0.25
        )
        let returned = PaneMapInteractiveZoomGeometry.frame(
            initialFrame: initialFrame,
            targetFrame: targetFrame,
            normalizedAnchor: anchor,
            gestureLocation: sourceAnchor,
            progress: 0
        )

        #expect(expanded.width > reversed.width)
        #expect(returned == initialFrame)
    }
}
