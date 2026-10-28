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
