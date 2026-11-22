@testable import CmuxNextActions
import Testing

/// A remote group's header menu can turn it back into rows of the one list (remote-groups-DESIGN.md
/// slice 5) without disconnecting the host: "Remove Remote Group", on every surface.
@MainActor @Suite struct RemoteGroupRemoveActionTests {
    @Test func removeRemoteGroupTargetsAMachine() throws {
        let action = try #require(ActionCatalog.all.first { $0.id == "remote.removeGroup" })
        #expect(action.targets == [.machine])
        #expect(action.cliName == "remote remove-group")
        #expect(action.surfacePlan.palette.isOffered)
        #expect(action.surfacePlan.cli?.isOffered == true && action.surfacePlan.mcpExemption == nil, "MCP offers it")
    }

    @Test func everyMachineHeaderMenuOffersIt() {
        let ids = ContextMenuCatalog.shared.entries(for: .machineSection).flatMap { entry -> [ActionID] in
            switch entry {
            case let .action(id), let .choices(id), let .submenu(id, _): [id]
            case let .folder(_, children), let .group(_, children): children.compactMap { if case let .action(id) = $0 { id } else { nil } }
            case .separator: []
            }
        }
        #expect(ids.contains("remote.removeGroup"))
    }
}
