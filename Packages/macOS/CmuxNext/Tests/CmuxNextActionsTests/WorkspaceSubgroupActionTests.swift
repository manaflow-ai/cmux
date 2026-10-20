@testable import CmuxNextActions
import Testing

/// "New Subgroup" (remote-groups-DESIGN.md slice 3): a group's right-click menu and the palette
/// make a group inside the targeted group (host > project > branch). One action, every surface.
@MainActor @Suite struct WorkspaceSubgroupActionTests {
    @Test func newSubgroupIsAGroupActionOnEverySurface() throws {
        let action = try #require(ActionCatalog.all.first { $0.id == "workspaceGroup.newSubgroup" })
        #expect(action.targets == [.workspaceGroup])
        #expect(action.cliName == "workspace-group new-subgroup")
        #expect(action.surfacePlan.palette.isOffered)
        #expect(action.surfacePlan.cli?.isOffered == true && action.surfacePlan.mcpExemption == nil, "MCP offers it")
        #expect(action.surfacePlan.cli?.isOffered == true)
    }

    @Test func newSubgroupIsATopLevelRowOfTheGroupMenu() {
        let top = ContextMenuCatalog.shared.entries(for: .workspaceGroup).compactMap { entry -> ActionID? in
            if case let .action(id) = entry { id } else { nil }
        }
        #expect(top.contains("workspaceGroup.newSubgroup"))
    }
}
