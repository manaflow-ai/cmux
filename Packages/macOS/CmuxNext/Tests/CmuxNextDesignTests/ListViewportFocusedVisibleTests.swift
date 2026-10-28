import CoreGraphics
@testable import CmuxNextDesign
import Testing
import CmuxNextDesignTokens

/// The sidebar invariant (Lawrence 2026-10-19): when the focused row moves, it
/// stays in view, whoever moved it; a user who scrolled away keeps the view
/// through changes that do not move the focused row.
@Suite struct ListViewportFocusedVisibleTests {
    /// Rows `ids` in order, 20 pt each, in a 100 pt viewport.
    private static func list(_ ids: [Int]) -> ListViewport<Int> {
        ListViewport(items: ids.enumerated().map { .init(id: $1, start: CGFloat($0) * 20, length: 20) },
                     viewport: 100, content: CGFloat(ids.count) * 20)
    }

    @Test func aFocusedRowMovedByAnotherClientScrollsIntoView() throws {
        let old = Self.list(Array(1...20))
        // Row 1 is focused and in view at the top; the CLI moves it to the end.
        let new = Self.list(Array(2...20) + [1])
        let offset = new.settle(from: old, offset: 0, focused: 1, newFocus: 1, padding: 0, userMoved: false)
        let row = try #require(new.item(1))
        #expect(new.isFullyVisible(row, at: offset, padding: 0), "the moved focused row is out of view at \(offset)")
    }

    @Test func aFocusedRowMovedWhileScrolledAwayScrollsIntoView() throws {
        let old = Self.list(Array(1...20))
        // Scrolled to the bottom, row 1 (focused) out of view; Move to Top of a sort moves it.
        let new = Self.list([2, 1] + Array(3...20))
        let offset = new.settle(from: old, offset: old.maxOffset, focused: 1, newFocus: 1, padding: 0, userMoved: false)
        let row = try #require(new.item(1))
        #expect(new.isFullyVisible(row, at: offset, padding: 0))
    }

    @Test func aFocusedRowPushedOutByARowArrivingAboveScrollsIntoView() throws {
        let old = Self.list(Array(1...20))
        // Row 5 is the last row in view; another client inserts row 99 above row 3, the anchor keeps row 1 in place.
        let new = Self.list([1, 2, 99] + Array(3...20))
        let offset = new.settle(from: old, offset: 0, focused: 5, newFocus: 5, padding: 0, userMoved: false)
        let row = try #require(new.item(5))
        #expect(new.isFullyVisible(row, at: offset, padding: 0))
    }

    @Test func aUserWhoScrolledAwayKeepsTheViewThroughAnUnrelatedClose() {
        let old = Self.list(Array(1...20))
        // Row 1 focused, out of view; row 15, in view, closes.
        let new = Self.list(Array(1...20).filter { $0 != 15 })
        let offset = new.settle(from: old, offset: 200, focused: 1, newFocus: 1, padding: 0, userMoved: false)
        #expect(offset > 100, "an unrelated close scrolled back to the focused row: \(offset)")
    }

    @Test func aCloseBesideTheFocusedRowIsNoMove() {
        let old = Self.list(Array(1...6))
        let new = Self.list([1, 2, 4, 5, 6])
        #expect(!old.movedByItself(2, in: new))
        #expect(!old.movedByItself(4, in: new))
        #expect(old.movedByItself(1, in: Self.list([2, 3, 1, 4, 5, 6])))
    }
}
