import CmuxNextWindowRules
import Testing

/// The chat placement and column rules answer through the app FFI (cmux-window-rules `chat`, whose own tests hold
/// the cases): these check the round trip, the facts the app sends and the answers it reads back.
@Suite struct WindowRulesChatTests {
    private static let chatDock = WindowRules.ChatDock(role: "agentChat", pinned: false, allowsTabs: false)

    /// Leo 2026-10-30: "IF I'M FOCUSED ON THE MAIN PANE OPEN IT THERE": Cmd-T in the chat dock keeps its page; a
    /// tool from it goes to the strip, and a tool dragged into it is refused.
    @Test func theChatDocksNewTabsGoToTheStrip() throws {
        let columns = [WindowRules.ChatColumn(panes: ["chat"], dock: Self.chatDock), WindowRules.ChatColumn(panes: ["page"], dock: nil)]
        let read = try #require(WindowRules().chatColumn(pane: "chat", columns: columns, moving: .init(samePane: false, chat: false)),
                                "the FFI did not answer")
        #expect(read.placement == .tab("page"))
        #expect(read.newChat == .dock("chat"))
        #expect(read.keepsNewTabPage && read.chatDock && read.takesOnlyChats && read.splitsDown && read.refusesMove)
        #expect(read.pagePick == "page")
    }

    /// A chat alone on its screen docks when the first tool opens; Cmd-I there focuses it.
    @Test func aLoneChatDocksAndCmdIFocusesIt() throws {
        let columns = [WindowRules.ChatColumn(panes: ["c"], dock: nil, loneChat: true)]
        let read = try #require(WindowRules().chatColumn(pane: "c", columns: columns), "the FFI did not answer")
        #expect(read.placement == .dockChat)
        let open = WindowRules.DockedOpen(user: true, targeted: false, hasArguments: false, canHost: true, dockRoles: true, pane: "c",
                                          read: read, pendingDock: false)
        #expect(WindowRules().dockedOpen(open) == .focus("c"))
    }

    @Test func aScriptedChatOpensAtTheWindowsRememberedPane() throws {
        let workspace = WindowRules.ChatWorkspace(id: "a", resourceId: "ws_a", key: "k", panes: [
            .init(id: "a1", resourceId: nil, focusedAt: 1), .init(id: "a2", resourceId: nil, focusedAt: 4),
        ])
        let window = WindowRules.ChatWindow(workspace: "a", recency: [], focusWorkspace: nil, focusedPane: nil, remembered: ["a": "a1"])
        let found = try #require(WindowRules().chatDestination(windows: [window], workspaces: [workspace]))
        #expect(found.workspace == 0 && found.pane == "a1")
        #expect(WindowRules().latestChatPane([workspace])?.pane == "a2")
        #expect(WindowRules().chatTarget(kind: "workspace", id: "ws_a", workspaces: [workspace])?.pane == "a2")
        #expect(WindowRules().chatCwd(given: nil, agentFolder: nil, tabs: ["/x", "/y"], selected: 1) == "/y")
    }

    @Test func columnActionsPlanOverTheColumnFound() throws {
        let rules = WindowRules()
        let actions = try #require(rules.columnActions())
        #expect(actions.planned.contains("column.cycleWidth"))
        #expect(actions.canvas.contains { $0.id == "canvasTidy" && $0.arrangement == "tidy" })
        let column = WindowRules.ActionColumn(width: 0.5, panes: ["p"], implicit: true, docked: false)
        let facts = WindowRules.ColumnFacts(column: column, left: nil, right: ["r"], recent: [], focused: nil, columnMove: false, handle: true)
        #expect(rules.columnPlan("column.moveRight", facts) == .swapPane(right: true, pane: "p"))
        #expect(rules.columnPlan("column.widthHalf", facts) == .refuse(.alreadyHasWidth, quiet: true))
        #expect(rules.columnAvailability("column.widthHalf", column: column) == .addSecondColumn)
        #expect(rules.dockNeeds(band: true, dockColumns: true, edgeDocks: false) == "edge-docks-v1")
    }
}
