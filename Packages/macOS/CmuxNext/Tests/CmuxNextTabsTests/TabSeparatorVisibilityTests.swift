import Testing
@testable import CmuxNextTabs

/// Chrome's separator rule: a separator shows only when neither neighbor is
/// selected, hovered or dragged. Separator `i` follows tab `i`; the last one
/// is the line before the + button and depends on the last tab only.
@Suite struct TabSeparatorVisibilityTests {
    private func visible(_ count: Int, selected: Int? = nil, hovered: Int? = nil, dragged: Int? = nil) -> [Int] {
        TabSeparatorVisibility.visibleSeparators(tabCount: count, selected: selected, hovered: hovered, dragged: dragged).sorted()
    }

    @Test func everySeparatorShowsWhenNoTabIsEmphasized() {
        #expect(visible(4) == [0, 1, 2, 3])
    }

    @Test func theSelectedTabHidesBothOfItsSeparators() {
        // Tab 2 of 5: the separators after tab 1 and after tab 2 hide.
        #expect(visible(5, selected: 2) == [0, 3, 4])
    }

    @Test func theHoveredTabHidesBothOfItsSeparators() {
        #expect(visible(5, selected: 0, hovered: 3) == [1, 4])
    }

    @Test func adjacentSelectedAndHoveredTabsHideThreeSeparators() {
        #expect(visible(5, selected: 1, hovered: 2) == [3, 4])
    }

    @Test func theSeparatorBeforePlusFollowsTheLastTab() {
        #expect(visible(3, selected: 2) == [0])
        #expect(visible(3, selected: 0, hovered: 2) == [])
        #expect(visible(3, selected: 1) == [2])
    }

    @Test func theFirstTabHasNoSeparatorBeforeIt() {
        #expect(visible(3, selected: 0) == [1, 2])
    }

    @Test func aDraggedTabHidesItsNeighborsSeparators() {
        #expect(visible(5, selected: 4, dragged: 1) == [2])
    }

    @Test func emptyRowsAndOutOfRangeIndicesAreSafe() {
        #expect(visible(0, selected: 0) == [])
        #expect(visible(2, selected: 7, hovered: -1) == [0, 1])
    }
}
