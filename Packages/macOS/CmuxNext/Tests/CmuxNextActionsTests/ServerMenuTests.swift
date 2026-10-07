@testable import CmuxNextActions
import Testing

/// The menu bar has a Server menu with Add Server… for every build, not only
/// DEV (Lawrence: "menubar which is Server, then add server").
@MainActor
struct ServerMenuTests {
    @Test func theServerMenuOffersAddServerInEveryBuild() throws {
        let registry = ActionRegistry.standard()
        let add = try #require(ActionCatalog.all.first { $0.id == "server.addServer" })
        #expect(add.mainMenu == .server)
        #expect(!add.isDebugOnly)
        #expect(add.surfaces.contains(.menu))
        // `cmux servers add --code CODE [--chief] [--name N]` runs this action (no window).
        #expect(add.surfacePlan.cli == .offered)
        #expect(add.cliName == "servers add")
        // Approving a server gives it account access: a person does it, not an MCP agent.
        #expect(add.surfacePlan.mcp == .exempt(.credentials))
        #expect(registry.makeMainMenuItems(for: .server).map(\.title).contains(add.title))
        let status = try #require(ActionCatalog.all.first { $0.id == "server.showPanel" })
        #expect(status.mainMenu == .server)
        #expect(!status.isDebugOnly)
    }
}
