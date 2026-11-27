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

    // MARK: Sized for the container (a cell held at its minimum, divider thickness)

    /// Panes 200 points wide at least (the app's minimum) and a 6 point divider, so clamping and dividers show.
    static func sizedModel(_ root: SplitNode) -> LayoutModel {
        let model = LayoutModel(screens: [LayoutScreen(id: "s", name: "s", layout: .splits(root))])
        model.followsDesignMetrics = false
        var style = LayoutStyle()
        style.minimumPaneContentSize = CGSize(width: 200, height: 64)
        style.dividerThickness = 6
        model.baseStyle = style
        return model
    }

    static func geometry(_ model: LayoutModel, _ viewport: CGSize) -> ScreenGeometry {
        ScreenGeometry.compute(model.screens[0].layout, viewport: viewport, style: model.style)
    }

    static func extents(_ model: LayoutModel, _ viewport: CGSize, _ panes: [PaneID], along axis: SplitAxis) -> [CGFloat] {
        let frames = geometry(model, viewport).panes
        return panes.map { pane in frames[pane].map { axis == .horizontal ? $0.width : $0.height } ?? -1 }
    }

    /// The stack X = C / (D | E | F) needs 3 x 200 + 2 x 6 = 612 points, more than a third of a 1200 point screen.
    /// Leaf counts gave A a third and left B what X did not take (A 398, B under its minimum, X 612). Sized for the
    /// screen, X keeps its 612 and A and B share the rest equally, in every shape of the chain and from every divider.
    static let wideStack = SplitNode.split("x", axis: .vertical, ratio: 0.4, a: .leaf("c"),
                                           b: .split("def", axis: .horizontal, ratio: 0.3, a: .leaf("d"),
                                                     b: .split("ef", axis: .horizontal, ratio: 0.6, a: .leaf("e"), b: .leaf("f"))))
    static let clampShapes: [String: SplitNode] = [
        "A|(B|X)": .split("outer", axis: .horizontal, ratio: 0.5, a: .leaf("a"),
                          b: .split("inner", axis: .horizontal, ratio: 0.5, a: .leaf("b"), b: wideStack)),
        "(A|B)|X": .split("outer", axis: .horizontal, ratio: 0.5,
                          a: .split("inner", axis: .horizontal, ratio: 0.2, a: .leaf("a"), b: .leaf("b")), b: wideStack),
        "A|(X|B)": .split("outer", axis: .horizontal, ratio: 0.7, a: .leaf("a"),
                          b: .split("inner", axis: .horizontal, ratio: 0.5, a: wideStack, b: .leaf("b"))),
    ]

    @Test(arguments: ["A|(B|X)", "(A|B)|X", "A|(X|B)"], ["outer", "inner"] as [SplitID])
    func aCellHeldAtItsMinimumLeavesTheOthersEven(shape: String, clicked: SplitID) throws {
        let viewport = CGSize(width: 1200, height: 800)
        let model = Self.sizedModel(try #require(Self.clampShapes[shape]))
        model.equalizeSplit(clicked, geometry: Self.geometry(model, viewport))
        let widths = Self.extents(model, viewport, ["a", "b", "c"], along: .horizontal)
        #expect(abs(widths[0] - widths[1]) <= 1, "\(shape) from \(clicked): A and B \(widths)")
        #expect(abs(widths[2] - 612) <= 1, "\(shape) from \(clicked): X keeps its minimum \(widths)")
        #expect(Self.ratio(model, "def") == 0.3 && Self.ratio(model, "x") == 0.4, "the stack keeps its own ratios")
    }

    /// Leaf counts on the same screen leave A and B uneven: the case the sizing fixes.
    @Test func leafCountsAloneLeaveTheClampedChainUneven() throws {
        let viewport = CGSize(width: 1200, height: 800)
        let model = Self.sizedModel(try #require(Self.clampShapes["A|(B|X)"]))
        model.equalizeSplit("outer")
        let widths = Self.extents(model, viewport, ["a", "b"], along: .horizontal)
        #expect(abs(widths[0] - widths[1]) > 50, "\(widths)")
    }

    /// The same for heights: A / (B / Y), Y = C | (D / E / F) needs 3 x 92 + 2 x 6 = 288 points of a 700 point screen.
    @Test(arguments: ["top", "lower"] as [SplitID])
    func aRowHeldAtItsMinimumLeavesTheOthersEven(clicked: SplitID) {
        let viewport = CGSize(width: 1200, height: 700)
        let tall = SplitNode.split("y", axis: .horizontal, ratio: 0.5, a: .leaf("c"),
                                   b: .split("de", axis: .vertical, ratio: 0.5, a: .leaf("d"),
                                             b: .split("ef", axis: .vertical, ratio: 0.5, a: .leaf("e"), b: .leaf("f"))))
        let model = Self.sizedModel(.split("top", axis: .vertical, ratio: 0.6, a: .leaf("a"),
                                           b: .split("lower", axis: .vertical, ratio: 0.2, a: .leaf("b"), b: tall)))
        model.equalizeSplit(clicked, geometry: Self.geometry(model, viewport))
        let heights = Self.extents(model, viewport, ["a", "b", "c"], along: .vertical)
        let minimum = 3 * model.style.minimumPaneSize.height + 2 * 6
        #expect(abs(heights[0] - heights[1]) <= 1, "A and B \(heights)")
        #expect(abs(heights[2] - minimum) <= 1, "Y keeps its minimum \(heights)")
    }

    /// Thick dividers: a four-pane chain A | (B | (C | D)) ends with every pane the same width to the device pixel
    /// (leaf counts put each nested divider's thickness on the deeper panes: 3 points apart here).
    @Test(arguments: ["p", "q", "r"] as [SplitID])
    func dividersInsideTheChainAreCounted(clicked: SplitID) {
        let viewport = CGSize(width: 1500, height: 800)
        let model = Self.sizedModel(.split("p", axis: .horizontal, ratio: 0.1, a: .leaf("a"),
                                           b: .split("q", axis: .horizontal, ratio: 0.9, a: .leaf("b"),
                                                     b: .split("r", axis: .horizontal, ratio: 0.4, a: .leaf("c"), b: .leaf("d")))))
        model.equalizeSplit(clicked, geometry: Self.geometry(model, viewport))
        let widths = Self.extents(model, viewport, ["a", "b", "c", "d"], along: .horizontal)
        #expect((widths.max() ?? 0) - (widths.min() ?? 1) <= 0.5, "\(widths)")
    }

    /// Panes that cannot all fit (five 200 point panes on 900 points): the layout shares by minimums, so the ratios
    /// fall back to leaf counts.
    @Test func panesThatCannotFitFallBackToLeafCounts() {
        let viewport = CGSize(width: 900, height: 800)
        let model = Self.sizedModel(.split("p", axis: .horizontal, ratio: 0.5, a: .leaf("a"),
                                           b: .split("q", axis: .horizontal, ratio: 0.5, a: .leaf("b"),
                                                     b: .split("r", axis: .horizontal, ratio: 0.5, a: .leaf("c"),
                                                               b: .split("s", axis: .horizontal, ratio: 0.5, a: .leaf("d"), b: .leaf("e"))))))
        model.equalizeSplit("r", geometry: Self.geometry(model, viewport))
        #expect(abs((Self.ratio(model, "p") ?? 0) - 0.2) < 1e-9)
        #expect(abs((Self.ratio(model, "s") ?? 0) - 0.5) < 1e-9)
    }

    /// A second double-click on a sized, already even chain sends nothing.
    @Test func anEvenSizedChainSendsNothing() throws {
        let viewport = CGSize(width: 1200, height: 800)
        let model = Self.sizedModel(try #require(Self.clampShapes["A|(B|X)"]))
        var intents: [LayoutIntent] = []
        model.intentHandler = { intents.append($0) }
        model.equalizeSplit("outer", geometry: Self.geometry(model, viewport))
        #expect(intents.count == 1)
        intents.removeAll()
        model.equalizeSplit("inner", geometry: Self.geometry(model, viewport))
        #expect(intents.isEmpty, "\(intents)")
    }

    /// Equalize Splits (the menu, Ctrl-Cmd-=) sizes each chain for the screen the same way.
    @Test func equalizeSplitsSizesItsChainsToo() throws {
        let viewport = CGSize(width: 1200, height: 800)
        let model = Self.sizedModel(try #require(Self.clampShapes["(A|B)|X"]))
        model.equalize(screen: "s", viewportWidth: viewport.width, geometry: Self.geometry(model, viewport))
        let widths = Self.extents(model, viewport, ["a", "b", "c", "d", "e"], along: .horizontal)
        #expect(abs(widths[0] - widths[1]) <= 1, "A and B \(widths)")
        #expect(abs(widths[3] - widths[4]) <= 1 && abs(widths[2] - 612) <= 1, "the stack and its own row \(widths)")
    }

    /// The water filling under the sizing: a share under a minimum is raised to it, the rest is shared equally, also
    /// when raising one share pushes another under its minimum.
    @Test func evenSharesRaiseOnlyWhatNeedsIt() {
        #expect(EvenSplitRatios.evenShares(of: 900, minimums: [100, 100, 100]) == [300, 300, 300])
        #expect(EvenSplitRatios.evenShares(of: 900, minimums: [100, 500, 100]) == [200, 500, 200])
        #expect(EvenSplitRatios.evenShares(of: 1000, minimums: [100, 450, 280, 100]) == [135, 450, 280, 135])
    }

    // MARK: Row edges

    /// A column of rows with `heights`; row `i` holds pane `pi`, or `roots[i]` when given.
    static func rowsColumn(_ heights: [Int], roots: [Int: SplitNode] = [:]) -> LayoutColumn {
        let rows = heights.enumerated().map { index, height in
            LayoutRow(id: RowID(rawValue: "r\(index)"), height: height, root: roots[index] ?? .leaf(PaneID(rawValue: "p\(index)")))
        }
        let chain = rows.dropFirst().reduce(rows[0].root) { tree, row in
            SplitNode.split(SplitID(rawValue: "row-\(row.id.rawValue)"), axis: .vertical, ratio: 0.5, a: tree, b: row.root)
        }
        return LayoutColumn(id: "c", width: 1, root: chain, rows: rows)
    }

    static func rowsModel(_ column: LayoutColumn) -> LayoutModel {
        let model = LayoutModel(screens: [LayoutScreen(id: "s", name: "s", layout: .columns([column]))])
        model.followsDesignMetrics = false
        model.acceptsRowOps = true
        return model
    }

    static func rowsModel(_ heights: [Int]) -> LayoutModel { rowsModel(rowsColumn(heights)) }

    /// A row edge's double-click evens the column's rows and fits them (`fit`, heights summing to 1000); before, it did
    /// nothing at all.
    @Test func aRowEdgeEvensTheColumnsRows() {
        let model = Self.rowsModel([700, 200, 450])
        var intents: [LayoutIntent] = []
        model.intentHandler = { intents.append($0) }
        model.equalizeRows("c")
        guard case let .setRowHeights(column, heights, fit)? = intents.first else {
            Issue.record("expected setRowHeights, got \(intents)")
            return
        }
        #expect(column == "c" && fit)
        #expect(heights.map(\.height).reduce(0, +) == 1000)
        #expect(Set(heights.map(\.height)).isSubset(of: [333, 334]), "\(heights)")
    }

    /// Sized for the column: a row whose panes need more than an even share keeps its minimum and the others end the
    /// same height on screen.
    @Test func aRowHeldAtItsMinimumLeavesTheOtherRowsEven() throws {
        let stack = SplitNode.split("tall", axis: .vertical, ratio: 0.5, a: .leaf("t1"),
                                    b: .split("tall2", axis: .vertical, ratio: 0.5, a: .leaf("t2"), b: .leaf("t3")))
        var column = Self.rowsColumn([300, 300, 300], roots: [2: stack])
        let model = Self.rowsModel(column)
        let layout = ScreenLayout.columns([column])
        let viewport = CGSize(width: 1200, height: 600)
        let before = ScreenGeometry.compute(layout, viewport: viewport, style: model.style)
        var intents: [LayoutIntent] = []
        model.intentHandler = { intents.append($0) }
        model.equalizeRows("c", stack: before.rowStacks["c"])
        guard case let .setRowHeights(_, heights, true)? = intents.first else {
            Issue.record("expected a fitting setRowHeights, got \(intents)")
            return
        }
        column.rows = zip(column.rows, heights).map { row, height in
            LayoutRow(id: row.id, height: height.height, root: row.root)
        }
        let after = try #require(ScreenGeometry.compute(.columns([column]), viewport: viewport, style: model.style).rowStacks["c"])
        let shown = after.rows.map(\.frame.height)
        let minimum = SplitGeometry.minimumSize(of: stack, style: model.style).height
        #expect(abs(shown[0] - shown[1]) <= 1.5, "\(shown)")
        #expect(shown[2] >= minimum - 0.5 && shown[2] <= minimum + 1.5, "the tall row keeps its minimum \(minimum): \(shown)")
    }

    /// Even already: nothing goes out. More rows than fit at 100‰ each: nothing either (the daemon would refuse).
    @Test func evenOrTooManyRowsSendNothing() {
        for heights in [[500, 500], Array(repeating: 90, count: 11)] {
            let model = Self.rowsModel(heights)
            var intents: [LayoutIntent] = []
            model.intentHandler = { intents.append($0) }
            model.equalizeRows("c")
            #expect(intents.isEmpty, "\(heights.count) rows: \(intents)")
        }
    }
}
