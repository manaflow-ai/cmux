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
        // The CLI verb is the owner's (`cmux servers add` runs server.pair.approve).
        #expect(add.surfacePlan.cli == .exempt(.ownerVerb))
        #expect(registry.makeMainMenuItems(for: .server).map(\.title).contains(add.title))
        let status = try #require(ActionCatalog.all.first { $0.id == "server.showPanel" })
        #expect(status.mainMenu == .server)
        #expect(!status.isDebugOnly)
    }
}
