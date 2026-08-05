import CoreGraphics
import CmuxMobileShellModel
import Testing
#if os(iOS)
import UIKit
#endif
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

    @Test func missingLayoutForcesTerminalRouteBeforeReconnect() {
        var state = PaneZoomPresentationState()
        state.presentPaneMap(from: "terminal-a")

        state.layoutAvailabilityDidChange(hasLayout: false)

        #expect(state.endpoint == .terminal)
        #expect(state.sourceSurfaceID == "terminal-a")
    }
}

#if os(iOS)
@MainActor
@Suite struct PaneMapColdOpenPrewarmTests {
    /// A restored workspace mounts the map as a covered navigation-stack root:
    /// UIKit never attaches it to a window or runs a layout pass, so without a
    /// pre-warm the zoom's matched source cells don't exist when the first
    /// terminal→map pop starts and the transition degrades to a hard cut.
    @Test func detachedMapMaterializesZoomSourceCellsBeforeFirstPop() {
        let panes = [
            MobilePaneNode(
                id: "alpha",
                selectedSurfaceID: "surface-alpha",
                surfaces: [
                    MobilePaneSurface(id: "surface-alpha", type: .terminal, title: "alpha")
                ]
            ),
            MobilePaneNode(
                id: "beta",
                selectedSurfaceID: "surface-beta",
                surfaces: [
                    MobilePaneSurface(id: "surface-beta", type: .terminal, title: "beta")
                ]
            ),
        ]
        let layout = MobilePaneLayout(
            version: 1,
            focusedPaneID: "alpha",
            root: .split(MobilePaneSplit(
                id: "root",
                orientation: .horizontal,
                ratio: 0.5,
                first: .pane(panes[0]),
                second: .pane(panes[1])
            ))
        )
        let items = panes.enumerated().map { index, pane in
            PaneMapCollectionItem(
                pane: pane,
                paneNumber: index + 1,
                paneCount: panes.count,
                isFocusedOnMac: pane.id == "alpha",
                selectedSurfaceID: pane.selectedSurfaceID,
                phoneSelectedSurfaceID: "surface-alpha",
                preview: nil,
                isLoadingPreview: false,
                agentStateKind: nil
            )
        }
        let representable = PaneMapCollectionView(
            items: items,
            layout: layout,
            terminalTheme: .monokai,
            zoomNamespace: Namespace().wrappedValue,
            overflowLabels: PaneMapOverflowLabels(
                leading: "leading",
                trailing: "trailing",
                top: "top",
                bottom: "bottom"
            ),
            allowsReordering: true,
            selectPreviewSurface: { _, _ in },
            jumpToTerminal: { _ in },
            reorderPanes: { _, _ in true }
        )
        let coordinator = PaneMapCollectionView.Coordinator(parent: representable)
        let collectionView = UICollectionView(
            frame: .zero,
            collectionViewLayout: PaneMapCollectionLayout(paneLayout: layout)
        )
        collectionView.register(
            UICollectionViewCell.self,
            forCellWithReuseIdentifier: PaneMapCollectionView.Coordinator.cellReuseIdentifier
        )
        collectionView.dataSource = coordinator
        collectionView.delegate = coordinator
        let container = PaneMapCollectionContainerView(collectionView: collectionView)
        container.frame = CGRect(x: 0, y: 0, width: 390, height: 700)
        coordinator.attach(collectionView: collectionView, container: container)

        coordinator.reconcile(items: items)

        #expect(container.window == nil)
        #expect(collectionView.numberOfItems(inSection: 0) == panes.count)
        #expect(collectionView.visibleCells.count == panes.count)
    }

    /// The navigation-stack root can also stay entirely unsized while covered;
    /// the pre-warm must impose the scene estimate itself before forcing layout.
    @Test func zeroSizedDetachedContainerAdoptsTheEstimatedSize() {
        let collectionView = UICollectionView(
            frame: .zero,
            collectionViewLayout: UICollectionViewFlowLayout()
        )
        let container = PaneMapCollectionContainerView(collectionView: collectionView)

        container.prewarmDetachedCellLayout(
            estimatedSize: CGSize(width: 390, height: 700)
        )

        #expect(container.bounds.size == CGSize(width: 390, height: 700))
        #expect(collectionView.bounds.size == CGSize(width: 390, height: 700))
    }
}

@MainActor
@Suite struct PaneZoomNavigationBackgroundBridgeTests {
    @Test func restoresOwnedAncestorBackgroundsWithoutClobberingNewOwners() {
        let originalRootColor = UIColor.red
        let originalContainerColor = UIColor.orange
        let root = UIViewController()
        root.view.backgroundColor = originalRootColor
        let container = UIView(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        container.backgroundColor = originalContainerColor
        root.view.addSubview(container)
        let bridge = PaneZoomNavigationBackgroundBridgeView(
            frame: CGRect(x: 0, y: 0, width: 1, height: 1)
        )
        container.addSubview(bridge)
        let window = UIWindow(frame: root.view.bounds)
        window.rootViewController = root
        window.isHidden = false

        bridge.color = .blue
        bridge.applyBackground()

        #expect(container.backgroundColor == .blue)
        #expect(root.view.backgroundColor == .blue)

        container.backgroundColor = .green
        bridge.restoreBackgrounds()

        #expect(container.backgroundColor == .green)
        #expect(root.view.backgroundColor == originalRootColor)
        window.isHidden = true
    }
}
#endif
