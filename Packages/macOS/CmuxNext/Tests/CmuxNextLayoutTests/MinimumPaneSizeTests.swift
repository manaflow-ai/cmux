import CoreGraphics
import Testing
@testable import CmuxNextLayout

/// Deep split trees used to leave panes with no room below their tab strip
/// ("collapsed", follow-up of #15771). Every pane now keeps
/// `LayoutStyle.minimumPaneSize` while its container has room.
@Suite struct MinimumPaneSizeTests {
    /// A vertical chain: a / (b / (c / (d / e))), each split at 0.5, so the
    /// innermost panes get 1/16 of the height without a subtree minimum.
    private func chain(_ count: Int, axis: SplitAxis) -> SplitNode {
        var node = SplitNode.leaf(PaneID("p\(count - 1)"))
        for index in stride(from: count - 2, through: 0, by: -1) {
            node = .split(SplitID("s\(index)"), axis: axis, ratio: 0.5, a: .leaf(PaneID("p\(index)")), b: node)
        }
        return node
    }

    @Test func deepChainKeepsEveryPaneAtTheMinimumHeight() {
        let style = LayoutStyle()
        let minimum = style.minimumPaneSize
        let tree = chain(5, axis: .vertical)
        let height = (minimum.height + style.dividerThickness) * 5
        let result = SplitGeometry.layout(tree, in: CGRect(x: 0, y: 0, width: 800, height: height), style: style)
        #expect(result.panes.count == 5)
        for (pane, frame) in result.panes {
            #expect(frame.height >= minimum.height - 0.5, "\(pane) is \(frame.height) pt tall")
        }
    }

    @Test func minimumSizeAddsSameAxisChainsAndTakesTheMaxAcross() {
        var style = LayoutStyle()
        style.paneChromeHeight = 30
        style.minimumPaneContentSize = CGSize(width: 100, height: 70)
        style.dividerThickness = 1
        let tree = SplitNode.split("s", axis: .horizontal, ratio: 0.5,
                                   a: .leaf("a"),
                                   b: .split("t", axis: .vertical, ratio: 0.5, a: .leaf("b"), b: .leaf("c")))
        #expect(SplitGeometry.minimumSize(of: tree, style: style) == CGSize(width: 201, height: 201))
    }

    @Test func chromeHeightFollowsTheDensityToken() {
        var style = LayoutStyle()
        style.paneChromeHeight = 36
        #expect(style.minimumPaneSize.height == 36 + style.minimumPaneContentSize.height)
    }

    @Test func tooSmallContainerSharesSpaceInProportionInsteadOfCollapsing() {
        let style = LayoutStyle()
        let tree = chain(8, axis: .vertical)
        let result = SplitGeometry.layout(tree, in: CGRect(x: 0, y: 0, width: 400, height: 400), style: style)
        let heights = result.panes.values.map(\.height)
        #expect(heights.allSatisfy { $0 > 30 }, "\(heights.sorted())")
        #expect((heights.max() ?? 0) - (heights.min() ?? 0) < 4)
    }

    @Test func dividerDragStopsAtTheSubtreeMinimum() {
        let style = LayoutStyle()
        let tree = SplitNode.split("s", axis: .vertical, ratio: 0.5, a: .leaf("a"), b: chain(3, axis: .vertical))
        let container = CGRect(x: 0, y: 0, width: 600, height: 900)
        let divider = try! #require(SplitGeometry.layout(tree, in: container, style: style).dividers.first { $0.id == "s" })
        let needB = SplitGeometry.minimumSize(of: chain(3, axis: .vertical), style: style).height
        #expect(divider.minimumB == needB)
        let ratio = SplitGeometry.ratio(forPointer: 880, container: container, axis: .vertical, style: style,
                                        minimumA: divider.minimumA, minimumB: divider.minimumB)
        let aExtent = CGFloat(ratio) * (container.height - style.dividerThickness)
        #expect(container.height - style.dividerThickness - aExtent >= needB - 0.5)
    }

    @Test func columnsWidenToFitSideBySidePanesUpToTheViewport() {
        var style = LayoutStyle()
        style.columnGap = 8
        let side = SplitNode.split("s", axis: .horizontal, ratio: 0.5,
                                   a: .split("t", axis: .horizontal, ratio: 0.5, a: .leaf("a"), b: .leaf("b")),
                                   b: .split("u", axis: .horizontal, ratio: 0.5, a: .leaf("c"), b: .leaf("d")))
        let layout = ScreenLayout.columns([LayoutColumn(id: "c1", width: 0.1, root: side), LayoutColumn(id: "c2", width: 0.5, root: .leaf("e"))])
        let geometry = ScreenGeometry.compute(layout, viewport: CGSize(width: 1000, height: 600), style: style)
        for pane in ["a", "b", "c", "d"] {
            #expect(geometry.panes[PaneID(pane)]!.width >= style.minimumPaneSize.width - 0.5)
        }
        let huge = ScreenLayout.columns([LayoutColumn(id: "c1", width: 0.5, root: chain(30, axis: .horizontal))])
        let capped = ScreenGeometry.compute(huge, viewport: CGSize(width: 1000, height: 600), style: style)
        #expect(capped.columns["c1"]!.width <= 1000 - 16)
    }
}

@Suite struct SplitRoomTests {
    private let viewport = CGSize(width: 1000, height: 600)

    @Test func splitScreenRefusesWhenAPaneWouldDropBelowTheMinimum() {
        let style = LayoutStyle()
        let one = ScreenLayout.splits(.leaf("a"))
        #expect(SplitRoom.placement(splitting: "a", axis: .vertical, in: one, viewport: viewport, style: style) == .split)
        // Keep splitting the bottom pane down until it cannot fit.
        var tree = SplitNode.leaf("p0")
        var last = PaneID("p0")
        var splits = 0
        while case .split = SplitRoom.placement(splitting: last, axis: .vertical, in: .splits(tree), viewport: viewport, style: style) {
            let next = PaneID("p\(splits + 1)")
            let target = last
            tree = tree.replacingLeaf(target) { .split(SplitID("s\(splits)"), axis: .vertical, ratio: 0.5, a: $0, b: .leaf(next)) }
            last = next
            splits += 1
            #expect(splits < 50)
        }
        let rows = Int((viewport.height + style.dividerThickness) / (style.minimumPaneSize.height + style.dividerThickness))
        #expect(splits + 1 == rows)
        #expect(SplitRoom.placement(splitting: last, axis: .vertical, in: .splits(tree), viewport: viewport, style: style) == .refused(.notEnoughRoom))
        // Every pane of the largest accepted tree keeps the minimum.
        let geometry = ScreenGeometry.compute(.splits(tree), viewport: viewport, style: style)
        #expect(geometry.panes.values.allSatisfy { $0.height >= style.minimumPaneSize.height - 0.5 })
    }

    @Test func narrowColumnOpensANewColumnForASideBySideSplit() {
        let style = LayoutStyle()
        let narrow = ScreenLayout.columns([LayoutColumn(id: "c1", width: 0.1, root: .leaf("a"))])
        #expect(SplitRoom.placement(splitting: "a", axis: .horizontal, in: narrow, viewport: viewport, style: style) == .newColumn)
        let wide = ScreenLayout.columns([LayoutColumn(id: "c1", width: 0.5, root: .leaf("a"))])
        #expect(SplitRoom.placement(splitting: "a", axis: .horizontal, in: wide, viewport: viewport, style: style) == .split)
    }

    @Test func fullColumnRefusesAStackedSplit() {
        let style = LayoutStyle()
        var tree = SplitNode.leaf("p0")
        for index in 1..<6 {
            tree = .split(SplitID("s\(index)"), axis: .vertical, ratio: 0.5, a: tree, b: .leaf(PaneID("p\(index)")))
        }
        let layout = ScreenLayout.columns([LayoutColumn(id: "c1", width: 0.5, root: tree)])
        #expect(SplitRoom.placement(splitting: "p5", axis: .vertical, in: layout, viewport: viewport, style: style) == .refused(.notEnoughRoom))
    }

    @Test func aSourcePaneThatLeavesFreesItsRoom() {
        let style = LayoutStyle()
        let short = CGSize(width: 1000, height: (style.minimumPaneSize.height + 1) * 2)
        let two = ScreenLayout.splits(.split("s", axis: .vertical, ratio: 0.5, a: .leaf("a"), b: .leaf("b")))
        #expect(SplitRoom.placement(splitting: "a", axis: .vertical, in: two, viewport: short, style: style) == .refused(.notEnoughRoom))
        #expect(SplitRoom.placement(splitting: "a", axis: .vertical, in: two, viewport: short, style: style, removing: "b") == .split)
    }

    @Test func unmeasuredViewportOrUnknownPaneDefersToTheDaemon() {
        let style = LayoutStyle()
        let one = ScreenLayout.splits(.leaf("a"))
        #expect(SplitRoom.placement(splitting: "a", axis: .vertical, in: one, viewport: .zero, style: style) == .split)
        #expect(SplitRoom.placement(splitting: "zz", axis: .vertical, in: one, viewport: viewport, style: style) == .split)
    }
}

@Suite struct KeepAliveBandTests {
    @Test func bandIsOneViewportWidthEachSide() {
        let viewport = CGRect(x: 0, y: 0, width: 1000, height: 600)
        let frames: [PaneID: CGRect] = [
            "visible": CGRect(x: 100, y: 0, width: 400, height: 600),
            "rightNear": CGRect(x: 1500, y: 0, width: 400, height: 600),
            "rightEdge": CGRect(x: 1990, y: 0, width: 400, height: 600),
            "rightFar": CGRect(x: 2100, y: 0, width: 400, height: 600),
            "leftNear": CGRect(x: -900, y: 0, width: 400, height: 600),
            "leftFar": CGRect(x: -1500, y: 0, width: 400, height: 600),
        ]
        #expect(KeepAliveBand.panes(displayed: frames, viewport: viewport) == ["visible", "rightNear", "rightEdge", "leftNear"])
    }

    @MainActor @Test func modelReportsKeepAliveAsASupersetOfVisible() {
        let model = LayoutModel()
        model.reportVisiblePanes(["a"], keepAlive: ["b"])
        #expect(model.visiblePanes == ["a"])
        #expect(model.keepAlivePanes == ["a", "b"])
    }
}
