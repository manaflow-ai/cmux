import Testing
@testable import CmuxNextActions

/// The agent chat's empty-space right-click menu (POLISH right-click contract; Leo, 2026-10-08:
/// the chat showed only macOS Services): Change Background… first, then zoom and the inspector,
/// each a catalog action placed in the `agentChat` menu.
struct AgentChatMenuTests {
    private var ids: [ActionID] {
        ContextMenuCatalog.shared.referencedIDs(ContextMenuCatalog.shared.entries(for: .agentChat))
    }

    @Test func emptySpaceLeadsWithChangeBackground() {
        #expect(ids.first == "appearance.changeBackground")
    }

    @Test(arguments: ["appearance.interfaceSize.increase", "appearance.interfaceSize.decrease",
                      "appearance.interfaceSize.reset", "agentPane.toggleInspector"] as [ActionID])
    func emptySpaceOffers(_ id: ActionID) {
        #expect(ids.contains(id))
    }

    /// Change Background… is a real action, so the palette and the menu run the same thing.
    @Test func changeBackgroundIsAPaletteAction() throws {
        let descriptor = try #require(ActionCatalog.all.first { $0.id == "appearance.changeBackground" })
        #expect(descriptor.title == "Change Background…")
        #expect(descriptor.surfacePlan.contextMenus.contains { $0.context == .agentChat })
    }
}
