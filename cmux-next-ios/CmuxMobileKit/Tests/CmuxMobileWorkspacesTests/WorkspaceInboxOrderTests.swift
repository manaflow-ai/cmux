import CmuxMobileModel
import Foundation
import Testing
@testable import CmuxMobileWorkspaces

/// The list follows the Mac's sidebar: Needs You, then Pinned in tile order,
/// then the rest in the Mac's order; newest first only when the order is unknown.
@Suite struct WorkspaceInboxOrderTests {
    let macs = [MacDevice(id: "m", name: "Studio", isOnline: true)]

    private func ws(_ id: String, index: Int?, pinned: Int? = nil, age: TimeInterval = 0, waiting: Bool = false) -> Workspace {
        var w = Workspace(id: id, macID: "m", title: id, directory: "~", tabs: [], lastActivityAt: Date(timeIntervalSince1970: 1000 - age),
                          needsAttention: waiting)
        w.sidebarIndex = index
        w.isPinned = pinned != nil
        w.pinIndex = pinned
        return w
    }

    @Test func pinnedThenTheMacsOrder() {
        let inbox = WorkspaceInbox(scope: .all, macs: macs, workspaces: [
            ws("new", index: 3, age: 0), ws("old", index: 0, age: 500), ws("mid", index: 1, age: 100),
            ws("p2", index: 2, pinned: 1), ws("p1", index: 4, pinned: 0), ws("asks", index: 5, waiting: true),
        ])
        #expect(inbox.needsYou.map(\.id) == ["asks"])
        #expect(inbox.pinned.map(\.id) == ["p1", "p2"])
        #expect(inbox.recent.map(\.id) == ["old", "mid", "new"])
        #expect(inbox.isMacOrder)
        #expect(inbox.macOrder(of: inbox.recent[1]).map(\.id) == ["old", "mid", "new"])
        // Pinned tiles are ordered on the Mac only (a layout move): no Move Up / Down.
        #expect(inbox.macOrder(of: inbox.pinned[0]).isEmpty)
        #expect(inbox.macSidebar("m").map(\.id) == ["p1", "p2", "old", "mid", "new", "asks"])
    }

    /// Two Macs' rows never interleave: each Mac's block in its own order.
    @Test func macsDoNotInterleave() {
        let macs = [MacDevice(id: "m", name: "Studio", isOnline: true), MacDevice(id: "n", name: "Air", isOnline: true)]
        var rows = [ws("a0", index: 0), ws("a1", index: 1)]
        for (id, index) in [("b0", 0), ("b1", 1)] {
            var w = ws(id, index: index)
            w.macID = "n"
            rows.append(w)
        }
        let inbox = WorkspaceInbox(scope: .all, macs: macs, workspaces: rows.shuffled())
        #expect(inbox.recent.map(\.id) == ["a0", "a1", "b0", "b1"])
    }

    @Test func newestFirstWithoutTheMacsOrder() {
        let inbox = WorkspaceInbox(scope: .all, macs: macs, workspaces: [ws("old", index: nil, age: 500), ws("new", index: nil, age: 0)])
        #expect(inbox.recent.map(\.id) == ["new", "old"])
        #expect(!inbox.isMacOrder)
        #expect(inbox.pinned.isEmpty)
    }
}
