import CmuxMobileModel
import Foundation
import Testing
@testable import CmuxMobileWorkspaces

/// The list's cost is O(changed rows) per update: its sections keep their
/// identity when the top row changes (a new section id tore down every row of
/// the old one), the inbox is built once per change of its inputs (it was
/// built about three times per body pass), and a row's Move Up / Down is a
/// lookup, not a scan of every row.
@Suite struct WorkspaceInboxIdentityTests {
    let macs = [MacDevice(id: "m", name: "Studio", isOnline: true)]
    let red = MacWorkspaceGroup(id: "grp_r", name: "Red", color: "red")

    private func ws(_ id: String, index: Int? = nil, age: TimeInterval = 0, group: MacWorkspaceGroup? = nil,
                    pinned: Int? = nil, waiting: Bool = false) -> Workspace {
        var w = Workspace(id: id, macID: "m", title: id, directory: "~", tabs: [], lastActivityAt: Date(timeIntervalSince1970: 1000 - age),
                          needsAttention: waiting)
        w.sidebarIndex = index
        w.group = group
        w.isPinned = pinned != nil
        w.pinIndex = pinned
        return w
    }

    /// Newest first: activity moves another row to the top; the one section keeps its id.
    @Test func newestFirstSectionKeepsItsIDWhenTheTopRowChanges() {
        let rows = [ws("a", age: 0), ws("b", age: 10), ws("c", age: 20)]
        let before = WorkspaceInbox(scope: .all, macs: macs, workspaces: rows)
        var moved = rows
        moved[2].lastActivityAt = Date(timeIntervalSince1970: 2000)
        let after = WorkspaceInbox(scope: .all, macs: macs, workspaces: moved)
        #expect(before.recent.first?.id == "a")
        #expect(after.recent.first?.id == "c")
        #expect(before.recentSections.map(\.id) == after.recentSections.map(\.id))
    }

    /// The Mac's order: a run's id is its Mac and group (and which run of them), not its first row.
    @Test func macOrderSectionsKeepTheirIDsWhenTheirFirstRowChanges() {
        let rows = [ws("a", index: 0), ws("b", index: 1, group: red), ws("c", index: 2, group: red), ws("d", index: 3)]
        let before = WorkspaceInbox(scope: .all, macs: macs, workspaces: rows)
        // "b" leaves the group's top: "c" leads it now.
        var reordered = rows
        reordered[1].sidebarIndex = 2
        reordered[2].sidebarIndex = 1
        let after = WorkspaceInbox(scope: .all, macs: macs, workspaces: reordered)
        #expect(after.recentSections[1].workspaces.first?.id == "c")
        #expect(before.recentSections.map(\.id) == after.recentSections.map(\.id))
        // Two loose runs of one Mac stay distinct.
        #expect(Set(after.recentSections.map(\.id)).count == after.recentSections.count)
    }

    @Test func memoBuildsOncePerChangeOfItsInputs() {
        let memo = WorkspaceInbox.Memo()
        let rows = [ws("a", age: 0), ws("b", age: 10)]
        let input = WorkspaceInbox.Memo.Input(scope: .all, macs: macs, workspaces: rows)
        let first = memo.inbox(input)
        _ = memo.inbox(input)
        _ = memo.inbox(WorkspaceInbox.Memo.Input(scope: .all, macs: macs, workspaces: rows))
        #expect(memo.builds == 1)
        #expect(memo.inbox(input) == first)
        var changed = rows
        changed[1].isWorking = true
        let next = memo.inbox(WorkspaceInbox.Memo.Input(scope: .all, macs: macs, workspaces: changed))
        #expect(memo.builds == 2)
        #expect(next.status(changed[1]) == .working)
        // The same ids in the same order: the membership key the list animates on does not change.
        let key = memo.workspaceIDsKey
        _ = memo.inbox(WorkspaceInbox.Memo.Input(scope: .all, macs: macs, workspaces: changed, query: "b"))
        #expect(memo.workspaceIDsKey == key)
        // A live reorder (a row went to the top) is not membership: the list moves it in place.
        _ = memo.inbox(WorkspaceInbox.Memo.Input(scope: .all, macs: macs, workspaces: changed.reversed()))
        #expect(memo.workspaceIDsKey == key)
        _ = memo.inbox(WorkspaceInbox.Memo.Input(scope: .all, macs: macs, workspaces: changed + [ws("z")]))
        #expect(memo.workspaceIDsKey != key)
    }

    /// Move Up / Down from a lookup agree with `macOrder(of:)` for every row.
    @Test func movesAgreeWithTheMacsOrder() {
        let rows = [ws("a", index: 0), ws("b", index: 1, group: red), ws("c", index: 2, group: red), ws("d", index: 3),
                    ws("p", index: 4, pinned: 0), ws("w", index: 5, waiting: true), ws("e", index: 6)]
        let inbox = WorkspaceInbox(scope: .all, macs: macs, workspaces: rows)
        for row in rows {
            let order = inbox.macOrder(of: row)
            let moves = inbox.moves(of: row)
            #expect(moves.up == (order.count > 1 && order.first?.id != row.id), "\(row.id) up")
            #expect(moves.down == (order.count > 1 && order.last?.id != row.id), "\(row.id) down")
            #expect(inbox.workspace(row.id) == row)
        }
        #expect(inbox.workspace("missing") == nil)
    }
}

/// The keyed sort orders exactly as `isNewer` does.
@Suite struct WorkspaceInboxSortTests {
    @Test func keyedSortMatchesIsNewer() {
        var rows: [Workspace] = []
        for index in 0..<120 {
            var w = Workspace(id: "w\(index)", macID: index % 3 == 0 ? "a" : "b", title: "\(index)", directory: "~", tabs: [],
                              lastActivityAt: Date(timeIntervalSince1970: Double((index * 37) % 50)), hasActivityTime: index % 5 != 0)
            w.sidebarIndex = index % 4 == 0 ? (index * 7) % 11 : nil
            w.focusOrder = (index * 13) % 7
            rows.append(w)
        }
        let order = Dictionary(rows.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
        let expected = rows.sorted { WorkspaceInbox.isNewer($0, $1, order: order) }.map(\.id)
        #expect(WorkspaceInbox.newestFirst(rows.shuffled(), order: order).map(\.id) == expected)
    }
}
