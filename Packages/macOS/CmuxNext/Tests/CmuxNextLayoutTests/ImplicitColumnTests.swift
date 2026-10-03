import Testing
@testable import CmuxNextLayout

/// Every screen is a column strip (coordinator decision 2026-10-02): a screen
/// stored as one split tree is one implicit column, so column actions answer
/// with column rules and never with "not in column layout".
@MainActor @Suite struct ImplicitColumnTests {
    private func model() -> LayoutModel {
        let root: SplitNode = .split("s", axis: .horizontal, ratio: 0.5, a: .leaf("a"), b: .leaf("b"))
        return LayoutModel(screens: [LayoutScreen(id: "screen", name: "1", layout: .splits(root))])
    }

    @Test func aSplitScreenHasOneImplicitColumnHoldingItsTree() {
        let model = model()
        let column = try! #require(model.stickyColumn(containing: "b"))
        #expect(column.root.panes == ["a", "b"])
        #expect(column.id == model.screens[0].implicitColumnID)
    }

    @Test func pinningTheOnlyColumnRefusesBecauseOneColumnMustScroll() {
        let model = model()
        let column = model.screens[0].implicitColumnID
        #expect(model.validateSticky(StickyColumn(), for: column) == .lastScrollingColumn)
        #expect(model.validateSticky(nil, for: column) == .unchanged)
    }

    @Test func anUnknownColumnIsReportedAsUnknown() {
        #expect(model().setColumnSticky("zz", StickyColumn()) == .unknownColumn)
    }
}
