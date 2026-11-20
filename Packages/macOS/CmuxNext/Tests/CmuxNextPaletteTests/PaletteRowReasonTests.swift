import AppKit
import CmuxNextActions
@testable import CmuxNextPalette
import Testing

/// Leo, 2026-11-17: "just... stop showijg the toggle on gui." A row whose run would refuse for the
/// focused object (`ActionTargetTitles.setPaletteReason`, `ActionTargetVisibility.gate`) or that
/// cannot run at all is not listed in the palette and no search finds it; it is back once it can
/// run. A CLI or MCP run of the same action still gets the reason.
@MainActor
struct PaletteRowReasonTests {
    private static func row(_ id: ActionID, in registry: ActionRegistry) -> PaletteItem? {
        RegistryPaletteProvider(registry: registry).makeItems().first { $0.actionID == id }
    }

    @Test func aRowThatWouldRefuseIsNotListed() throws {
        let registry = ActionRegistry.standard()
        registry.context = ActionContext(rawValue: .max)
        registry.bind("agentPane.toggleFiles") {}
        var reason: String? = "Toggle Files Beside Chat isn't available in this chat."
        ActionTargetTitles.setPaletteReason("agentPane.toggleFiles", in: registry) { reason }
        #expect(Self.row("agentPane.toggleFiles", in: registry) == nil, "a row that cannot run here is listed")
        reason = nil
        let offered = try #require(Self.row("agentPane.toggleFiles", in: registry), "a row that runs is not listed")
        #expect(offered.isEnabled)
        #expect(offered.subtitle == nil)
    }

    /// The chat's controls the page offers (`AgentPageCommand`): each row is left out while the chat
    /// does not offer it and listed once it does.
    @Test(arguments: [
        ("agentPane.runInBackground", "Run in Background"),
        ("agentPane.toggleQueueing", "Toggle Prompt Queueing"),
        ("agentPane.showSubagents", "Show Subagents in Session Info"),
        ("agentPane.showBackgroundTasks", "Show Background Tasks in Session Info"),
    ])
    func aChatControlRowIsLeftOutWhileTheChatDoesNotOfferIt(id: String, title: String) throws {
        let registry = ActionRegistry.standard()
        registry.context = ActionContext(rawValue: .max)
        let action = ActionID(rawValue: id)
        registry.bind(action) {}
        var reason: String? = "Not available in this chat."
        ActionTargetTitles.setPaletteReason(action, in: registry) { reason }
        #expect(Self.row(action, in: registry) == nil, "\(id) is listed while the chat does not offer it")
        reason = nil
        let offered = try #require(Self.row(action, in: registry), "\(id) is not listed once the chat offers it")
        #expect(offered.title == title)
        #expect(offered.isEnabled)
        #expect(offered.subtitle == nil)
    }

    /// A gated row (`ActionTargetVisibility.gate`) is absent from the palette and from a typed search,
    /// and the run the CLI or MCP makes still returns the reason.
    @Test func aGatedRowIsNotListedNorFoundAndTheCLIStillHearsWhy() async throws {
        let registry = ActionRegistry.standard()
        registry.context = ActionContext(rawValue: .max)
        var ran = 0
        registry.bind("agentPane.toggleFiles") { ran += 1 }
        registry.bind("newWindow") {}
        let why = "Toggle Files Beside Chat isn't available in this chat."
        var gated = true
        ActionTargetVisibility.gate("agentPane.toggleFiles", in: registry) { _ in gated ? why : nil }
        let items = RegistryPaletteProvider(registry: registry).makeItems()
        #expect(!items.contains { $0.actionID == "agentPane.toggleFiles" }, "an unavailable row is listed")
        #expect(items.contains { $0.actionID == "newWindow" && $0.isEnabled }, "an available row is not listed")
        _ = NSApplication.shared
        let palette = PaletteController(registry: registry, sources: PaletteSources(), frecencyPersistence: nil)
        defer { palette.closeForTest() }
        palette.show(.commands)
        await palette.model.settle()
        palette.model.send(.setQuery("Toggle Files Beside Chat"))
        await palette.model.settle()
        #expect(!palette.model.rows.contains { $0.item.actionID == "agentPane.toggleFiles" }, "a search finds a row that cannot run here")
        palette.model.send(.setQuery("New Window"))
        await palette.model.settle()
        #expect(palette.model.rows.contains { $0.item.actionID == "newWindow" }, "a search does not find a row that runs")
        let refusal = registry.capturingRefusal {
            #expect(!registry.perform("agentPane.toggleFiles", invocation: ActionInvocation()))
        }
        #expect(refusal == why, "the CLI is not told why: \(refusal ?? "nothing")")
        #expect(ran == 0)
        gated = false
        #expect(Self.row("agentPane.toggleFiles", in: registry)?.isEnabled == true, "the row does not come back once it runs")
    }

    /// A row its action disables (`isEnabled` false, `bind(_:unavailable:)`) is left out the same way.
    @Test func aDisabledActionIsNotListed() throws {
        let registry = ActionRegistry.standard()
        registry.context = ActionContext(rawValue: .max)
        var on = false
        registry.bind("newWindow", isEnabled: { on }) {}
        registry.bind("cloudOpenDesktop", unavailable: { on ? nil : "Account is unavailable" }, invoke: { _ in })
        #expect(Self.row("newWindow", in: registry) == nil)
        #expect(Self.row("cloudOpenDesktop", in: registry) == nil)
        #expect(registry.unavailableReason(for: "cloudOpenDesktop") == "Account is unavailable", "the CLI is not told why")
        on = true
        #expect(Self.row("newWindow", in: registry)?.isEnabled == true)
        #expect(Self.row("cloudOpenDesktop", in: registry)?.isEnabled == true)
    }
}
