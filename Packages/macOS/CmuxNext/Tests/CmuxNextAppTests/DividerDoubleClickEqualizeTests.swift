import CmuxNextBridge
import CoreGraphics
@testable import CmuxNextLayout
import Testing

/// A split divider's double-click equalizes (https://github.com/manaflow-ai/cmux/issues/57175: "it doesn't always
/// equalize the splits… it equalizes weirdly"). It set only the clicked split's own ratio to its share of cells, which
/// assumes every same-axis split nested under it is even already and leaves the splits above it alone: after one inner
/// divider was dragged, a double-click on the outer one gave thirds of 1/3, 0.53 and 0.13. Now the double-click evens
/// the whole same-axis chain the divider belongs to, from whichever of its dividers it lands on, and leaves
/// perpendicular subtrees (and other chains) as they were.
@MainActor
struct DividerDoubleClickEqualizeTests {
    static let viewport = CGSize(width: 1800, height: 1200)

    static func model(_ root: SplitNode) -> LayoutModel {
        let model = LayoutModel(screens: [LayoutScreen(id: "s", name: "s", layout: .splits(root))])
        model.followsDesignMetrics = false
        var style = LayoutStyle()
        style.minimumPaneContentSize = CGSize(width: 40, height: 40)
        model.baseStyle = style
        return model
    }

    static func frames(_ model: LayoutModel) -> [PaneID: CGRect] {
        ScreenGeometry.compute(model.screens[0].layout, viewport: viewport, style: model.style).panes
    }

    /// The on-screen extents of `panes` along `axis` are equal (to a point: dividers and pixel rounding).
    static func expectEven(_ model: LayoutModel, _ panes: [PaneID], along axis: SplitAxis, _ note: Comment) {
        let frames = frames(model)
        let extents = panes.map { pane in frames[pane].map { axis == .horizontal ? $0.width : $0.height } ?? -1 }
        let first = extents[0]
        #expect(first > 0 && extents.allSatisfy { abs($0 - first) <= 1.5 }, "\(note): \(extents)")
    }

    static func ratio(_ model: LayoutModel, _ split: SplitID) -> Double? { model.screens[0].layout.ratio(of: split) }

    /// A | (B | C), the inner divider dragged to 0.8: either divider's double-click gives three equal columns.
    @Test(arguments: ["outer", "inner"] as [SplitID])
    func horizontalChainEvensFromEitherDivider(clicked: SplitID) {
        let model = Self.model(.split("outer", axis: .horizontal, ratio: 0.5, a: .leaf("a"),
                                      b: .split("inner", axis: .horizontal, ratio: 0.8, a: .leaf("b"), b: .leaf("c"))))
        model.equalizeSplit(clicked)
        Self.expectEven(model, ["a", "b", "c"], along: .horizontal, "double-click on \(clicked)")
    }

    /// (A | B) | (C | D) with every ratio off: any of the three dividers gives four equal columns.
    @Test(arguments: ["root", "left", "right"] as [SplitID])
    func balancedChainEvensFromAnyDivider(clicked: SplitID) {
        let model = Self.model(.split("root", axis: .horizontal, ratio: 0.7,
                                      a: .split("left", axis: .horizontal, ratio: 0.2, a: .leaf("a"), b: .leaf("b")),
                                      b: .split("right", axis: .horizontal, ratio: 0.9, a: .leaf("c"), b: .leaf("d"))))
        model.equalizeSplit(clicked)
        Self.expectEven(model, ["a", "b", "c", "d"], along: .horizontal, "double-click on \(clicked)")
    }

    /// A stack of three rows, then A / (B / C) vertical: the same holds for heights.
    @Test(arguments: ["top", "lower"] as [SplitID])
    func verticalChainEvensFromEitherDivider(clicked: SplitID) {
        let model = Self.model(.split("top", axis: .vertical, ratio: 0.15, a: .leaf("a"),
                                      b: .split("lower", axis: .vertical, ratio: 0.3, a: .leaf("b"), b: .leaf("c"))))
        model.equalizeSplit(clicked)
        Self.expectEven(model, ["a", "b", "c"], along: .vertical, "double-click on \(clicked)")
    }

    /// Mixed: A | (B / (C | D)). The outer horizontal chain has two cells (A and the stack), so A and the stack end
    /// equal widths; the vertical split and the C | D split under it are other chains and keep their ratios.
    @Test func mixedDirectionsKeepPerpendicularSubtrees() {
        let model = Self.model(.split("h", axis: .horizontal, ratio: 0.8, a: .leaf("a"),
                                      b: .split("v", axis: .vertical, ratio: 0.3, a: .leaf("b"),
                                                b: .split("cd", axis: .horizontal, ratio: 0.25, a: .leaf("c"), b: .leaf("d")))))
        model.equalizeSplit("h")
        let frames = Self.frames(model)
        let a = frames["a"]?.width ?? -1, stack = frames["b"]?.width ?? -2
        #expect(abs(a - stack) <= 1.5, "A and the stack: \(a) vs \(stack)")
        #expect(Self.ratio(model, "v") == 0.3, "the vertical split is another chain")
        #expect(Self.ratio(model, "cd") == 0.25, "the C | D split is another chain")

        // The vertical divider: B and the C | D row end equal heights; C | D still keeps its ratio.
        model.equalizeSplit("v")
        Self.expectEven(model, ["b", "c"], along: .vertical, "double-click on v")
        #expect(Self.ratio(model, "cd") == 0.25)

        // The C | D divider: C and D end equal widths, the outer split stays where it was.
        model.equalizeSplit("cd")
        Self.expectEven(model, ["c", "d"], along: .horizontal, "double-click on cd")
        #expect(Self.ratio(model, "h") == 0.5)
    }

    /// (A | B) / (C | (D | E)): a horizontal chain under a vertical split stops at the vertical split. Its three cells
    /// even out from either of its dividers; the other row's chain and the vertical split stay.
    @Test(arguments: ["cde", "de"] as [SplitID])
    func chainStopsAtPerpendicularParent(clicked: SplitID) {
        let model = Self.model(.split("rows", axis: .vertical, ratio: 0.4,
                                      a: .split("ab", axis: .horizontal, ratio: 0.7, a: .leaf("a"), b: .leaf("b")),
                                      b: .split("cde", axis: .horizontal, ratio: 0.6, a: .leaf("c"),
                                                b: .split("de", axis: .horizontal, ratio: 0.1, a: .leaf("d"), b: .leaf("e")))))
        model.equalizeSplit(clicked)
        Self.expectEven(model, ["c", "d", "e"], along: .horizontal, "double-click on \(clicked)")
        #expect(Self.ratio(model, "ab") == 0.7)
        #expect(Self.ratio(model, "rows") == 0.4)
    }

    /// A same-axis chain inside a column of a columns screen evens too (`tree(containing:)` finds the column's tree).
    @Test func chainInsideAColumnEvens() {
        let column = LayoutColumn(id: "c", width: 1, root: .split("top", axis: .vertical, ratio: 0.5, a: .leaf("a"),
                                                                  b: .split("low", axis: .vertical, ratio: 0.85, a: .leaf("b"), b: .leaf("c"))))
        let model = LayoutModel(screens: [LayoutScreen(id: "s", name: "s", layout: .columns([column]))])
        model.equalizeSplit("top")
        #expect(abs((model.screens[0].layout.ratio(of: "top") ?? 0) - 1.0 / 3) < 1e-9)
        #expect(model.screens[0].layout.ratio(of: "low") == 0.5)
    }

    /// The ratios go to the daemon as one change: one intent, one transaction (one undo step).
    @Test func sendsOneChange() {
        let model = Self.model(.split("outer", axis: .horizontal, ratio: 0.5, a: .leaf("a"),
                                      b: .split("inner", axis: .horizontal, ratio: 0.8, a: .leaf("b"), b: .leaf("c"))))
        var intents: [LayoutIntent] = []
        model.intentHandler = { intents.append($0) }
        model.equalizeSplit("outer")
        #expect(intents.count == 1, "\(intents)")
        guard case let .setLayoutSizes(sizes, _)? = intents.first else {
            Issue.record("expected one setLayoutSizes, got \(intents)")
            return
        }
        #expect(sizes.count == 2)

        // Already even: nothing goes out.
        intents.removeAll()
        model.equalizeSplit("inner")
        #expect(intents.isEmpty, "\(intents)")
    }
}
