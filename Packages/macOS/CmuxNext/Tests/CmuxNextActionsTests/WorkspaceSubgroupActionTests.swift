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

    /// `cmux workspace group create --parent GROUP --name N` and MCP name the parent and the new name.
    @Test func newSubgroupTakesAParentAndANameForTheCLIAndMCP() throws {
        let action = try #require(ActionCatalog.all.first { $0.id == "workspaceGroup.newSubgroup" })
        let group = try #require(action.arguments.first { $0.name == "group" })
        #expect(group.kind == .target(.workspaceGroup))
        #expect(!group.isRequired)
        let name = try #require(action.arguments.first { $0.name == "name" })
        #expect(!name.isRequired)
    }

    /// In the group menu's Options folder: the menu's top level holds 12 rows (ActionSurfaceParityTests).
    @Test func theGroupMenuOffersNewSubgroup() {
        func ids(_ entries: [ContextMenuEntry]) -> [ActionID] {
            entries.flatMap { entry -> [ActionID] in
                switch entry {
                case let .action(id), let .choices(id), let .submenu(id, _): [id]
                case let .folder(_, children), let .group(_, children): ids(children)
                case .separator: []
                }
            }
        }
        #expect(ids(ContextMenuCatalog.shared.entries(for: .workspaceGroup)).contains("workspaceGroup.newSubgroup"))
    }
}
