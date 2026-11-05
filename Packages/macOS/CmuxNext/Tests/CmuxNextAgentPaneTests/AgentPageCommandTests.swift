import CmuxNextActions
import Testing
@testable import CmuxNextAgentPane

/// The chat's controls in the palette (``AgentPageCommand``): the header's toggles, Run in Background,
/// queueing and Session Info's sections. Each runs only where the target chat's page lists it, is
/// honest about why not, and never runs by automation that did not ask for focus.
@Suite(.serialized)
@MainActor
struct AgentPageCommandTests {
    private actor NoHost: AgentPaneHostProviding {
        func handshake(sessionId: String?) async throws -> AgentPaneHandshake { throw AgentPaneHostError.daemonStopped }
    }

    @Test func thePageListsTheCommandsItOffersNow() async {
        let model = AgentPaneModel(host: NoHost(), sessionId: "session-a")
        _ = await model.respond(to: AgentPaneRequest(body: ["method": "pane.commandAvailability",
                                                            "params": ["commands": ["toggleFiles", "toggleSideTabs"]]]))
        #expect(model.pageCommands == ["toggleFiles", "toggleSideTabs"])
        _ = await model.respond(to: AgentPaneRequest(body: ["method": "pane.commandAvailability", "params": ["commands": [String]()]]))
        #expect(model.pageCommands.isEmpty)
        #expect(AgentPaneRequest(body: ["method": "pane.commandAvailability", "params": [:]]) == .unsupported("pane.commandAvailability"))
    }

    @Test func everyCommandIsACatalogAction() {
        let registry = ActionRegistry.standard()
        for command in AgentPageCommand.allCases {
            #expect(registry.descriptor(for: ActionID(command)) != nil, "\(command)")
        }
        let bound = registry.bindAgentPageCommands(available: { _ in [] }, run: { _, _ in })
        #expect(bound)
    }

    @Test func aCommandTheTargetPageDoesNotOfferRefusesWithItsReason() {
        let registry = ActionRegistry.standard()
        registry.context = ActionContext(rawValue: .max)
        var ran: [AgentPageCommand] = []
        // Pane "b" offers the side tabs; the focused pane (no target) offers nothing.
        registry.bindAgentPageCommands(available: { invocation in
            invocation.target?.id == "b" ? ["toggleSideTabs"] : []
        }, run: { command, _ in ran.append(command) })
        let focused = ActionInvocation(origin: .cli, focusRequested: true)
        let paneB = ActionInvocation(target: ActionTargetRef(kind: .pane, id: "b"), origin: .cli, focusRequested: true)
        #expect(ActionTargetReasons.reason(for: "agentPane.toggleFiles", invocation: paneB, in: registry)
            == "Toggle Files Beside Chat isn't available in this chat.")
        #expect(ActionTargetReasons.reason(for: "agentPane.toggleSideTabs", invocation: paneB, in: registry) == nil)
        // The palette runs on the focused chat, so its row is disabled while that chat lacks it; the
        // subtitle beside the title does not repeat it.
        #expect(registry.action(for: "agentPane.toggleSideTabs")?.paletteUnavailableReason?()
            == "Not available in this chat.")
        let refusal = registry.capturingRefusal { registry.perform("agentPane.toggleSideTabs", invocation: focused) }
        #expect(refusal == "Toggle Tabs Beside Chat isn't available in this chat.")
        #expect(ran.isEmpty)
        registry.perform("agentPane.toggleSideTabs", invocation: paneB)
        #expect(ran == [.toggleSideTabs])
    }

    @Test func automationMustRequestFocusBeforeRunningACommand() {
        let registry = ActionRegistry.standard()
        registry.context = ActionContext(rawValue: .max)
        var ran: [AgentPageCommand] = []
        registry.bindAgentPageCommands(available: { _ in Set(AgentPageCommand.allCases.map(\.rawValue)) }, run: { command, _ in ran.append(command) })
        let refusal = registry.capturingRefusal {
            registry.perform("agentPane.togglePreview", invocation: ActionInvocation(origin: .cli))
        }
        #expect(refusal == "Toggle Preview Beside Chat requires focus.")
        #expect(ran.isEmpty)
        registry.perform("agentPane.togglePreview", invocation: ActionInvocation(origin: .cli, focusRequested: true))
        #expect(ran == [.togglePreview])
    }

    /// Run in Background, queueing and Session Info's sections: bound like the header's toggles, run
    /// when the focused chat's page offers them, greyed out with their own title when it does not.
    @Test(arguments: [
        (AgentPageCommand.runInBackground, "Run in Background"),
        (.toggleQueueing, "Toggle Prompt Queueing"),
        (.showSubagents, "Show Subagents in Session Info"),
        (.showBackgroundTasks, "Show Background Tasks in Session Info"),
    ])
    func theChatsControlsRunWhereThePageOffersThem(command: AgentPageCommand, title: String) {
        let registry = ActionRegistry.standard()
        registry.context = ActionContext(rawValue: .max)
        let id = ActionID(command)
        #expect(registry.descriptor(for: id)?.title == title)
        var offered: Set<String> = []
        var ran: [AgentPageCommand] = []
        // Bound outside #expect, so its closures need not be Sendable.
        let bound = registry.bindAgentPageCommands(available: { _ in offered }, run: { command, _ in ran.append(command) })
        #expect(bound)
        let focused = ActionInvocation(origin: .cli, focusRequested: true)
        let reason = "\(title) isn't available in this chat."
        #expect(registry.action(for: id)?.paletteUnavailableReason?() == "Not available in this chat.")
        let refusal = registry.capturingRefusal { registry.perform(id, invocation: focused) }
        #expect(refusal == reason)
        #expect(ran.isEmpty)
        offered = [command.rawValue]
        #expect(registry.action(for: id)?.paletteUnavailableReason?() == nil)
        registry.perform(id, invocation: focused)
        #expect(ran == [command])
    }

    /// The user, 2026-11-03: "'toggle' options are very confusing, since we don't know the current
    /// state". Files, Preview and Tabs Beside Chat say in the palette whether they are on for the
    /// focused chat, from the header's state the App last gave its page (the lit splits and whether
    /// the panes beside the chat show); the chat's other controls have no state to show.
    @Test func theHeaderTogglesSayWhetherTheyAreOnInThePalette() throws {
        let registry = ActionRegistry.standard()
        registry.context = ActionContext(rawValue: .max)
        let model = AgentPaneModel(host: NoHost(), sessionId: "session-a")
        var header = AgentPaneHeaderState(sessionInfo: false, browserOpensPreview: false)
        var hooks = AgentPaneHeaderHooks(run: { _, _ in }, tabState: { header })
        hooks.shown = { header }
        model.header = hooks
        var focused: AgentPaneModel? = model
        let bound = registry.bindAgentPageCommands(available: { _ in Set(AgentPageCommand.allCases.map(\.rawValue)) },
                                                   state: { focused?.header?.shown?() }, run: { _, _ in })
        #expect(bound)
        func on(_ command: AgentPageCommand) -> Bool? { registry.action(for: ActionID(command))?.paletteState?() }
        #expect(on(.toggleFiles) == false)
        #expect(on(.togglePreview) == false)
        #expect(on(.toggleSideTabs) == false)

        header.lit = [AgentPaneModel.filesAction]
        header.sideTabs = true
        #expect(on(.toggleFiles) == true)
        #expect(on(.togglePreview) == false)
        #expect(on(.toggleSideTabs) == true)

        header.lit = [AgentPaneModel.previewAction, "splitRight"]
        header.sideTabs = false
        #expect(on(.toggleFiles) == false)
        #expect(on(.togglePreview) == true)
        #expect(on(.toggleSideTabs) == false)

        // No chat focused: nothing is on.
        focused = nil
        #expect(on(.togglePreview) == false)
        // Run in Background, queueing (the page's own choice) and Session Info's sections show no switch.
        for command in [AgentPageCommand.runInBackground, .toggleQueueing, .showSubagents, .showBackgroundTasks] {
            #expect(on(command) == nil, "\(command)")
        }
    }
}
