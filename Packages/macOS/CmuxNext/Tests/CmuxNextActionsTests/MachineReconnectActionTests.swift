@testable import CmuxNextActions
import Testing

/// Reconnect on every remote machine header (remote-groups-DESIGN.md 8.2): paired servers and Cloud
/// machines get the row SSH hosts already had, from the header menu, the palette, the CLI and MCP.
@MainActor @Suite struct MachineReconnectActionTests {
    @Test func reconnectTargetsAMachineOnEverySurface() throws {
        let action = try #require(ActionCatalog.all.first { $0.id == "machine.reconnect" })
        #expect(action.targets == [.machine])
        #expect(action.cliName == "machine reconnect")
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
        #expect(ids.contains("machine.reconnect"))
    }
}
