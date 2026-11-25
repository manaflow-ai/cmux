import CmuxNextActions
import Testing

@Suite
struct AgentChatMenuActionCatalogTests {
    private static let menuIDs: [String] = [
        "agentPane.toggleDisplaySettings",
        "agentPane.replayConversation",
        "agentPane.editInstructions",
        "agentPane.addProjectFiles",
        "agentPane.markUnread",
        "agentPane.moveToFloatingChat",
        "agentPane.toggleMinimap",
        "agentPane.revealCwdInFinder",
        "agentPane.openCwdInTerminal",
    ]

    @Test func menuActionsArePaletteCliAndMcpRows() throws {
        let descriptors = Dictionary(uniqueKeysWithValues: ActionCatalog.all.map { ($0.id.rawValue, $0) })
        for id in Self.menuIDs {
            let action = try #require(descriptors[id], "missing (id)")
            #expect(action.isPaletteVisible)
            #expect(action.surfacePlan.cli?.isOffered == true)
            #expect(action.surfacePlan.mcp?.isOffered == true)
            #expect(action.requires.contains(.agentPaneFocused))
            #expect(action.targets.contains(.pane))
        }
    }

    @Test func menuActionIDsDoNotDuplicateAnExistingCatalogRow() {
        let ids = ActionCatalog.all.map(\.id.rawValue)
        #expect(Set(ids).count == ids.count)
    }

    @Test func newChatCatalogSharesDestinationArgumentsAndPaletteKeyword() throws {
        let chat = try #require(ActionCatalog.all.first { $0.id.rawValue == "palette.newAgentChat" })
        #expect(chat.cliName == "agent new-chat")
        #expect(chat.arguments.map(\.name) == ["cwd", "harness", "model", "host"])
        #expect(chat.keywords.contains("acpmux"))
        let on = try #require(ActionCatalog.all.first { $0.id.rawValue == "palette.newAgentChatOn" })
        #expect(on.title.contains("New Agent Chat on"))
        #expect(on.arguments.map(\.name) == ["host"])
        #expect(on.surfacePlan.cli?.isOffered == false)
        #expect(on.surfacePlan.mcp?.isOffered == false)
    }

    @Test func pageMenuActionsGrantViewChangePermissionToCliAndMCPScopes() throws {
        let descriptors = Dictionary(uniqueKeysWithValues: ActionCatalog.all.map { ($0.id.rawValue, $0) })
        for id in Self.menuIDs where id != "agentPane.markUnread" && !id.contains("Cwd") {
            let action = try #require(descriptors[id], "missing (id)")
            #expect(action.focuses)
            let invocation = ActionInvocation(origin: .cli)
            #expect(ActionRunScope(invocation, focuses: action.focuses).allowsViewChange)
        }
    }
}
