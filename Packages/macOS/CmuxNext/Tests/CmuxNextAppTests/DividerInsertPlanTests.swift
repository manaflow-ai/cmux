@testable import CmuxNextLayout
import Testing

/// Insert New at a divider (Leo 2026-11-07): the pane opens between the divider's two sides and the three share
/// the split's old extent in thirds. The same rule as cmux-layout-reducer `divider_insert`, whose tests run the
/// shown tree; these pin the app's plan (target, wrapped side, sizing) and Hide Divider's line.
struct DividerInsertPlanTests {
    static func split(_ id: String, _ axis: SplitAxis, _ a: SplitNode, _ b: SplitNode, ratio: Double = 0.5) -> SplitNode {
        .split(SplitID(id), axis: axis, ratio: ratio, a: a, b: b)
    }

    @Test func twoPanesSplitTheFirstAndMoveTheDividerToTwoThirds() throws {
        for axis in [SplitAxis.horizontal, .vertical] {
            let tree = Self.split("s", axis, .leaf("a"), .leaf("b"))
            let plan = try #require(tree.dividerInsertPlan(at: "s"))
            #expect(plan.target == "a")
            #expect(plan.around == nil)
            #expect(plan.axis == axis)
            #expect(plan.sizing == [SplitRatioChange(split: "s", ratio: 2.0 / 3.0)])
        }
    }

    @Test func aNestedFirstSideIsWrappedWhole() throws {
        // (x / y) | b: the new pane spans the divider's full height, after y.
        let tree = Self.split("s", .horizontal, Self.split("inner", .vertical, .leaf("x"), .leaf("y")), .leaf("b"))
        let plan = try #require(tree.dividerInsertPlan(at: "s"))
        #expect(plan.target == "y")
        #expect(plan.around == "inner")
    }

    @Test func aDividerInAChainOfThreeIsFound() throws {
        // a | (b | c): the divider between b and c.
        let tree = Self.split("outer", .horizontal, .leaf("a"), Self.split("bc", .horizontal, .leaf("b"), .leaf("c")), ratio: 1.0 / 3)
        let plan = try #require(tree.dividerInsertPlan(at: "bc"))
        #expect(plan.target == "b")
        #expect(plan.around == nil)
        #expect(tree.dividerInsertPlan(at: "gone") == nil)
    }

    @Test func theDividerBesideAPaneIsTheOneAfterItElseBeforeIt() {
        let tree = Self.split("outer", .horizontal, .leaf("a"), Self.split("bc", .vertical, .leaf("b"), .leaf("c")))
        #expect(tree.divider(beside: "a") == "outer")
        #expect(tree.divider(beside: "b") == "bc")
        #expect(tree.divider(beside: "c") == "bc")
        #expect(SplitNode.leaf("a").divider(beside: "a") == nil)
    }

    @MainActor @Test func aHiddenDividerDrawsNoLineAtRestButLightsWhenGrabbed() {
        let handle = DividerHandleView(kind: .split(SplitID("s")), axis: .horizontal)
        #expect(handle.isLineVisible)
        handle.isLineHidden = true
        #expect(!handle.isLineVisible)
        handle.setHovered(true)
        #expect(handle.isLineVisible)
    }
}
