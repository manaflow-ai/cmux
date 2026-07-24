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

@Suite struct PaneZoomPresentationStateTests {
    @Test func bothDirectionsKeepTheSameStableZoomSource() {
        var state = PaneZoomPresentationState()

        state.presentPaneMap(from: "terminal-a")
        #expect(state.endpoint == .paneMap)
        #expect(state.sourceSurfaceID == "terminal-a")

        state.presentTerminal(surfaceID: "terminal-b")
        #expect(state.endpoint == .terminal)
        #expect(state.sourceSurfaceID == "terminal-b")

        state.presentationDidChange(isTerminalPresented: false)
        #expect(state.endpoint == .paneMap)
        #expect(state.sourceSurfaceID == "terminal-b")
    }

    @Test func anInteractiveCancellationDoesNotDiscardTheSource() {
        var state = PaneZoomPresentationState()
        state.presentTerminal(surfaceID: "terminal-a")

        state.presentationDidChange(isTerminalPresented: false)
        state.presentationDidChange(isTerminalPresented: true)

        #expect(state.endpoint == .terminal)
        #expect(state.sourceSurfaceID == "terminal-a")
    }

    @Test func startsWithTheRestoredTerminalAlreadyInstalledInItsLocalPath() {
        var state = PaneZoomPresentationState()

        #expect(state.navigationPath == [.terminal])
        #expect(state.isTerminalPresented)

        state.navigationPathDidChange([])
        #expect(state.endpoint == .paneMap)

        state.presentTerminal(surfaceID: "terminal-a")
        #expect(state.navigationPath == [.terminal])
        state.navigationPathDidChange([.terminal])
        #expect(state.endpoint == .terminal)
    }

    @Test func anEmptyTerminalIDCannotBreakTheMatchedSource() {
        var state = PaneZoomPresentationState()
        state.presentTerminal(surfaceID: "terminal-a")
        state.presentTerminal(surfaceID: "")

        #expect(state.endpoint == .terminal)
        #expect(state.sourceSurfaceID == "terminal-a")
    }
}

@Suite struct PaneMapReorderStateTests {
    @Test func failureRollsBackToTheLatestAuthoritativeOrder() throws {
        var state = PaneMapReorderState(authoritativePaneIDs: ["left", "middle", "right"])

        let pendingRequest = state.beginMove(from: 0, to: 2)
        let request = try #require(pendingRequest)
        #expect(state.visiblePaneIDs == ["middle", "right", "left"])

        state.reconcile(authoritativePaneIDs: ["left", "right", "middle"])
        #expect(
            state.visiblePaneIDs == ["middle", "right", "left"],
            "An in-flight optimistic move must remain stable while the Mac refresh arrives"
        )

        #expect(state.complete(requestID: request.id, succeeded: false) == .rolledBack)
        #expect(state.visiblePaneIDs == ["left", "right", "middle"])
        #expect(!state.isMutationPending)
    }

    @Test func successWaitsForAndThenUsesTheAuthoritativeMacOrder() throws {
        var state = PaneMapReorderState(authoritativePaneIDs: ["one", "two", "three"])

        let pendingRequest = state.beginMove(from: 2, to: 0)
        let request = try #require(pendingRequest)
        #expect(request.orderedPaneIDs == ["three", "one", "two"])
        #expect(state.complete(requestID: request.id, succeeded: true) == .awaitingAuthority)
        #expect(state.visiblePaneIDs == ["three", "one", "two"])
        #expect(state.isMutationPending)

        state.reconcile(authoritativePaneIDs: ["one", "two", "three"])
        #expect(state.visiblePaneIDs == ["one", "two", "three"])
        #expect(!state.isMutationPending)
    }

    @Test func staleCompletionCannotOverwriteANewerMove() throws {
        var state = PaneMapReorderState(authoritativePaneIDs: ["a", "b", "c"])

        let firstPendingRequest = state.beginMove(from: 0, to: 1)
        let first = try #require(firstPendingRequest)
        #expect(state.complete(requestID: first.id, succeeded: false) == .rolledBack)

        let secondPendingRequest = state.beginMove(from: 2, to: 0)
        let second = try #require(secondPendingRequest)
        #expect(state.complete(requestID: first.id, succeeded: true) == .ignored)
        #expect(state.visiblePaneIDs == second.orderedPaneIDs)
        #expect(state.isMutationPending)
    }

    @Test func scrollAndDragMovementDoNotResolveAsPaneSelection() {
        var arbitration = PaneMapSelectionArbitration()

        arbitration.touchBegan(at: CGPoint(x: 10, y: 10))
        arbitration.touchMoved(to: CGPoint(x: 32, y: 10))
        let movementResolvedAsTap = arbitration.touchEnded(at: CGPoint(x: 32, y: 10))
        #expect(!movementResolvedAsTap)

        arbitration.touchBegan(at: CGPoint(x: 10, y: 10))
        arbitration.dragSessionDidBegin()
        let dragResolvedAsTap = arbitration.touchEnded(at: CGPoint(x: 10, y: 10))
        #expect(!dragResolvedAsTap)

        arbitration.touchBegan(at: CGPoint(x: 10, y: 10))
        let stationaryTouchResolvedAsTap = arbitration.touchEnded(at: CGPoint(x: 11, y: 11))
        #expect(stationaryTouchResolvedAsTap)
    }
}
