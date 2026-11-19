import CmuxMobileModel
import CmuxMobileWorkspaces
import Foundation
import Testing

/// The Workspaces cache keeps each Mac's first rows in the order the list shows a cached Mac
/// (`LiveSnapshot.listOrder`), so a launch reads only those and the rest joins below them. That
/// order must be the inbox's, or the rows read later would land above the first screen.
@Suite struct WorkspacesCacheOrderTests {
    static let mac = MacDevice(id: "m1", name: "Studio", isOnline: true)
    static let now = Date(timeIntervalSince1970: 1_800_000_000)

    static func rows(sidebarOrder: Bool) -> [Workspace] {
        return (0..<300).map { index in
            var ws = Workspace(id: "ws-\(index)", macID: mac.id, title: "w\(index)", directory: "/src",
                               tabs: [], lastActivityAt: now.addingTimeInterval(-Double((index * 7_919) % 5_000)),
                               hasActivityTime: index % 11 != 0, focusOrder: (index * 31) % 97)
            ws.isPinned = index % 37 == 3
            ws.pinIndex = ws.isPinned ? (300 - index) : nil
            ws.sidebarIndex = sidebarOrder ? (index * 13) % 300 : nil
            return ws
        }
    }

    @Test(arguments: [true, false])
    func listOrderIsTheInboxOrderForACachedMac(sidebarOrder: Bool) {
        let rows = Self.rows(sidebarOrder: sidebarOrder)
        let ordered = LiveSnapshot.listOrder(rows)
        let inbox = WorkspaceInbox(scope: .all, macs: [Self.mac], workspaces: ordered,
                                   context: .init(phases: [Self.mac.id: .cached(.connecting)]))
        #expect(inbox.needsYou.isEmpty)
        #expect((inbox.pinned + inbox.recent).map(\.id) == ordered.map(\.id))
        // Built from the store's own order (not the cache's), the inbox shows the same list.
        let fromStore = WorkspaceInbox(scope: .all, macs: [Self.mac], workspaces: rows,
                                       context: .init(phases: [Self.mac.id: .cached(.connecting)]))
        #expect((fromStore.pinned + fromStore.recent).map(\.id) == ordered.map(\.id))
    }
}
