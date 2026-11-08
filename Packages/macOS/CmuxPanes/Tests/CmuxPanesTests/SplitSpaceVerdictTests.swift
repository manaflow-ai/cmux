import Bonsplit
import Foundation
import Testing
@testable import CmuxPanes

@Suite("Split space verdict")
struct SplitSpaceVerdictTests {
    private func pane(_ id: String, x: Double = 0, y: Double, width: Double = 1200, height: Double) -> ExternalTreeNode {
        .pane(ExternalPaneNode(
            id: id,
            frame: PixelRect(x: x, y: y, width: width, height: height),
            tabs: [],
            selectedTabId: nil
        ))
    }

    private func split(
        _ orientation: String,
        _ first: ExternalTreeNode,
        _ second: ExternalTreeNode,
        dividerPosition: Double = 0.5
    ) -> ExternalTreeNode {
        .split(ExternalSplitNode(
            id: UUID().uuidString,
            orientation: orientation,
            dividerPosition: dividerPosition,
            first: first,
            second: second
        ))
    }

    private func verdict(
        _ tree: ExternalTreeNode,
        splitting paneId: String,
        _ orientation: String = "vertical",
        minimum: Double = 100,
        dividerPosition: Double? = nil
    ) -> SplitSpaceVerdict {
        tree.splitSpaceVerdict(
            splittingPaneId: paneId,
            orientation: orientation,
            minimumExtent: minimum,
            dividerThickness: 1,
            dividerPosition: dividerPosition
        )
    }

    /// The layout #15371 reached after four splits down in an 860 pt column:
    /// each split halved the focused (last) pane.
    private func halvedColumn() -> ExternalTreeNode {
        split("vertical",
              pane("a", y: 0, height: 430),
              split("vertical",
                    pane("b", y: 430, height: 215),
                    split("vertical",
                          pane("c", y: 645, height: 107.5),
                          split("vertical",
                                pane("d", y: 752.5, height: 53.75),
                                pane("e", y: 806.25, height: 53.75)))))
    }

    @Test func aPaneWithRoomForTwoHalvesFits() {
        #expect(verdict(pane("a", y: 0, height: 860), splitting: "a") == .fits)
        #expect(verdict(halvedColumn(), splitting: "a") == .fits)
    }

    @Test func anExplicitDividerPositionMustLeaveBothChildrenAtTheMinimum() {
        let tree = pane("a", y: 0, height: 300)
        #expect(verdict(tree, splitting: "a", dividerPosition: 0.66) == .fits)
        #expect(verdict(tree, splitting: "a", dividerPosition: 0.9) == .noSpace)
        // Bonsplit clamps even more extreme requests to 0.9.
        #expect(verdict(tree, splitting: "a", dividerPosition: 0.99) == .noSpace)
    }

    @Test func aSmallPaneBorrowsFromItsColumn() {
        // Splitting e in place gives two 26 pt panes; six equal slots in the
        // 860 pt column give each about 143 pt.
        #expect(verdict(halvedColumn(), splitting: "e") == .fitsAfterEqualizingRun)
    }

    @Test func aFullColumnRefusesTheSplit() {
        // Three 100 pt panes cannot fit in 300 pt with their dividers.
        let tree = split("vertical", pane("a", y: 0, height: 150), pane("b", y: 150, height: 150))
        #expect(verdict(tree, splitting: "b") == .noSpace)
    }

    @Test func aSmallPaneWithoutASameOrientationRunRefuses() {
        // b sits in a side-by-side split, so a split down has nothing to
        // borrow from in its column.
        let tree = split("horizontal",
                         pane("a", x: 0, y: 0, width: 600, height: 150),
                         pane("b", x: 600, y: 0, width: 600, height: 150))
        #expect(verdict(tree, splitting: "b") == .noSpace)
        #expect(verdict(pane("a", y: 0, height: 150), splitting: "a") == .noSpace)
    }

    @Test func widthUsesTheHorizontalAxis() {
        let tree = split("horizontal",
                         pane("a", x: 0, y: 0, width: 200, height: 860),
                         pane("b", x: 200, y: 0, width: 200, height: 860))
        #expect(verdict(tree, splitting: "b", "horizontal", minimum: 160) == .noSpace)
        #expect(verdict(tree, splitting: "b", "vertical", minimum: 100) == .fits)
    }

    @Test func aStackedSlotNeedsRoomForEachOfItsPanes() {
        // a | (b over c) | d side by side, 400 pt wide, and d (150 pt) is
        // being split right. Its halves would be 74.5 pt; equal quarters
        // give each slot 99.25 pt, and the stacked slot only needs one
        // pane's width, so a 90 pt minimum fits after equalizing.
        let stacked = split("vertical",
                            pane("b", x: 125, y: 0, width: 125, height: 430),
                            pane("c", x: 125, y: 430, width: 125, height: 430))
        let tree = split("horizontal",
                         pane("a", x: 0, y: 0, width: 125, height: 860),
                         split("horizontal", stacked, pane("d", x: 250, y: 0, width: 150, height: 860)))
        #expect(verdict(tree, splitting: "d", "horizontal", minimum: 90) == .fitsAfterEqualizingRun)
        // A slot that nests another side-by-side split needs both widths.
        let nested = split("vertical",
                           split("horizontal",
                                 pane("b", x: 125, y: 0, width: 62.5, height: 430),
                                 pane("x", x: 187.5, y: 0, width: 62.5, height: 430)),
                           pane("c", x: 125, y: 430, width: 125, height: 430))
        let crowded = split("horizontal",
                            pane("a", x: 0, y: 0, width: 125, height: 860),
                            split("horizontal", nested, pane("d", x: 250, y: 0, width: 150, height: 860)))
        #expect(verdict(crowded, splitting: "d", "horizontal", minimum: 90) == .noSpace)
    }

    @Test func aNestedSplitKeepsItsProportionWhenTheRunEqualizes() {
        // a | S | d in 1400 pt, where S stacks (b | x at 0.6) over c. Equal
        // thirds give S about 466 pt, but x keeps 40% of S, so x needs S to
        // be 400 pt for a 160 pt minimum; a fourth slot (349 pt) would leave
        // x at 140 pt.
        let nested = ExternalTreeNode.split(ExternalSplitNode(
            id: UUID().uuidString,
            orientation: "horizontal",
            dividerPosition: 0.6,
            first: pane("b", x: 700, y: 0, width: 240, height: 430),
            second: pane("x", x: 940, y: 0, width: 160, height: 430)
        ))
        let slot = split("vertical", nested, pane("c", x: 700, y: 430, width: 400, height: 430))
        let tree = split("horizontal",
                         pane("a", x: 0, y: 0, width: 700, height: 860),
                         split("horizontal", slot, pane("d", x: 1100, y: 0, width: 300, height: 860)))
        #expect(verdict(tree, splitting: "d", "horizontal", minimum: 160) == .noSpace)
    }

    @Test func anEleventhExactCapacitySlotAccountsForBonsplitRatioClamping() {
        // Ten 100 pt panes plus ten 1 pt dividers would arithmetically fit an
        // eleventh pane in 1110 pt. Equalizing this right-heavy tree asks its
        // root for a 1/11 ratio, however, and Bonsplit clamps that to 0.1.
        // The remaining ten slots receive less than their exact capacity.
        var tree = pane("target", x: 1000, y: 0, width: 110, height: 860)
        for index in stride(from: 8, through: 0, by: -1) {
            tree = split(
                "horizontal",
                pane("p\(index)", x: Double(index) * 100, y: 0, width: 100, height: 860),
                tree
            )
        }
        #expect(verdict(tree, splitting: "target", "horizontal", minimum: 100) == .noSpace)
    }

    @Test func anUnmeasuredLayoutAllowsTheSplit() {
        let tree = split("vertical", pane("a", y: 0, height: 0), pane("b", y: 0, height: 0))
        #expect(verdict(tree, splitting: "b") == .fits)
        #expect(verdict(tree, splitting: "missing") == .fits)
    }
}
