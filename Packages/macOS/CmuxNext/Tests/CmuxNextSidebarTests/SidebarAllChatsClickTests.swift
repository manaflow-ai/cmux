import AppKit
import CmuxNextDesign
import Testing
@testable import CmuxNextSidebar

/// nxdog81 preflight (Lawrence: clicking opens the chat to the right): a real mouse click on an
/// All chats row only selected it, because the table took the click; one click must open it (the
/// cloud tree rule). The row view gets the press, and the table never selects a row.
@MainActor @Suite(.serialized) struct SidebarAllChatsClickTests {
    private func chats() -> SidebarChatsView {
        let view = SidebarChatsView(frame: NSRect(x: 0, y: 0, width: 260, height: 400),
                                    defaults: UserDefaults(suiteName: "all-chats-click-\(UUID())")!)
        view.update([SidebarChatsView.Row(id: "codex:a", title: "A", harness: "codex", brand: nil),
                     SidebarChatsView.Row(id: "codex:b", title: "B", harness: "codex", brand: nil)], enabled: true, ready: true)
        view.layoutSubtreeIfNeeded()
        return view
    }

    @Test func aMouseDownOnARowReachesTheRowNotTheTablesSelection() throws {
        let view = chats()
        let table = view.chatTable
        let row = try #require(table.view(atColumn: 0, row: 1, makeIfNecessary: true) as? SidebarItemRowView)
        let down = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                   windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        #expect(table.validateProposedFirstResponder(row, for: down), "the row view handles its own click")
        #expect(view.tableView(table, shouldSelectRow: 1) == false, "a click never just selects a chat")
    }

    @Test func pressingARowOpensItsChat() throws {
        let view = chats()
        var opened: [String] = []
        view.onOpen = { opened.append($0) }
        let row = try #require(view.chatTable.view(atColumn: 0, row: 1, makeIfNecessary: true) as? SidebarItemRowView)
        row.press(at: .zero)
        #expect(opened == ["codex:b"])
    }
}
