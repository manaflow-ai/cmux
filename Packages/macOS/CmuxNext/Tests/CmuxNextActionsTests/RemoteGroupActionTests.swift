@testable import CmuxNextActions
import Testing

/// New Remote Group (remote-groups-DESIGN.md slice 4): one action makes a host a remote group, from
/// the palette, the sidebar's + and background menu, the CLI (`cmux remote new-group <host>`) and MCP.
@MainActor @Suite struct RemoteGroupActionTests {
    @Test func newRemoteGroupIsOneActionOnEverySurface() throws {
        let action = try #require(ActionCatalog.all.first { $0.id == "remote.newGroup" })
        #expect(action.cliName == "remote new-group")
        #expect(action.surfacePlan.palette.isOffered)
        #expect(action.surfacePlan.cli?.isOffered == true)
        #expect(action.surfacePlan.cli?.isOffered == true && action.surfacePlan.mcpExemption == nil, "MCP offers it")
        #expect(action.arguments.contains { $0.name == "destination" })
    }

    /// The palette lists the hosts to pick (connected, Tailscale, `~/.ssh/config`) and still takes typed
    /// text; the CLI's `--name` names the group.
    @Test func newRemoteGroupSuggestsHostsAndTakesAName() throws {
        let action = try #require(ActionCatalog.all.first { $0.id == "remote.newGroup" })
        let destination = try #require(action.arguments.first { $0.name == "destination" })
        #expect(destination.suggestions?.source == ActionSuggestions.remoteHosts)
        let name = try #require(action.arguments.first { $0.name == "name" })
        #expect(!name.isRequired)
    }

    @Test func theSidebarBackgroundMenuOffersIt() {
        func ids(_ entries: [ContextMenuEntry]) -> [ActionID] {
            entries.flatMap { entry -> [ActionID] in
                switch entry {
                case let .action(id), let .choices(id), let .submenu(id, _): [id]
                case let .folder(_, children), let .group(_, children): ids(children)
                case .separator: []
                }
            }
        }
        #expect(ids(ContextMenuCatalog.shared.entries(for: .sidebarBackground)).contains("remote.newGroup"))
    }
}
