#if os(iOS)
import Foundation
import Testing
@testable import CmuxMobileShellUI

@Suite("Workspace list native array move")
struct WorkspaceListNativeArrayMoveTests {
    @Test("moving one row downward uses the original destination coordinate")
    func moveOneDownward() {
        var values = ["a", "b", "c", "d"]

        values.moveWorkspaceListElements(fromOffsets: IndexSet(integer: 1), toOffset: 4)

        #expect(values == ["a", "c", "d", "b"])
    }

    @Test("moving discontiguous rows preserves their order")
    func moveDiscontiguousRowsToStart() {
        var values = ["a", "b", "c", "d"]

        values.moveWorkspaceListElements(fromOffsets: IndexSet([1, 3]), toOffset: 0)

        #expect(values == ["b", "d", "a", "c"])
    }

    @Test("moving adjacent rows downward adjusts for removed predecessors")
    func moveAdjacentRowsDownward() {
        var values = ["a", "b", "c", "d"]

        values.moveWorkspaceListElements(fromOffsets: IndexSet([1, 2]), toOffset: 4)

        #expect(values == ["a", "d", "b", "c"])
    }
}
#endif
