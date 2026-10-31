import CmuxNextActions
@testable import CmuxNextPalette
import Testing

/// A row whose run would refuse for the focused object (`ActionTargetTitles.setPaletteReason`) is
/// disabled with that reason instead of closing the palette and refusing after the pick.
@MainActor
struct PaletteRowReasonTests {
    @Test func aRowThatWouldRefuseIsDisabledWithItsReason() throws {
        let registry = ActionRegistry.standard()
        registry.context = ActionContext(rawValue: .max)
        registry.bind("agentPane.toggleFiles") {}
        var reason: String? = "Toggle Files Beside Chat isn't available in this chat."
        ActionTargetTitles.setPaletteReason("agentPane.toggleFiles", in: registry) { reason }
        func row() throws -> PaletteItem {
            try #require(RegistryPaletteProvider(registry: registry).makeItems().first { $0.actionID == "agentPane.toggleFiles" })
        }
        let refused = try row()
        #expect(!refused.isEnabled)
        #expect(refused.subtitle == "Toggle Files Beside Chat isn't available in this chat.")
        reason = nil
        let offered = try row()
        #expect(offered.isEnabled)
        #expect(offered.subtitle == nil)
    }

    /// The chat's controls the page offers (`AgentPageCommand`): each row greys out with the chat's
    /// reason and runs once the chat offers it.
    @Test(arguments: [
        ("agentPane.runInBackground", "Run in Background"),
        ("agentPane.toggleQueueing", "Toggle Prompt Queueing"),
        ("agentPane.showSubagents", "Show Subagents in Session Info"),
        ("agentPane.showBackgroundTasks", "Show Background Tasks in Session Info"),
    ])
    func aChatControlRowIsDisabledWhileTheChatDoesNotOfferIt(id: String, title: String) throws {
        let registry = ActionRegistry.standard()
        registry.context = ActionContext(rawValue: .max)
        let action = ActionID(rawValue: id)
        registry.bind(action) {}
        var reason: String? = "Not available in this chat."
        ActionTargetTitles.setPaletteReason(action, in: registry) { reason }
        func row() throws -> PaletteItem {
            try #require(RegistryPaletteProvider(registry: registry).makeItems().first { $0.actionID == action })
        }
        let refused = try row()
        #expect(refused.title == title)
        #expect(!refused.isEnabled)
        #expect(refused.subtitle == "Not available in this chat.")
        reason = nil
        let offered = try row()
        #expect(offered.isEnabled)
        #expect(offered.subtitle == nil)
    }
}
