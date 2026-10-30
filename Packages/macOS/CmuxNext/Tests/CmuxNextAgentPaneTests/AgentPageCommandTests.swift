import CmuxNextActions
import Testing
@testable import CmuxNextAgentPane

/// The chat header's toggles in the palette (``AgentPageCommand``): run only where the target chat's
/// page lists them, honest about why not, and never run by automation that did not ask for focus.
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
        // The palette runs on the focused chat, so its row is disabled with that chat's reason.
        #expect(registry.action(for: "agentPane.toggleSideTabs")?.paletteUnavailableReason?()
            == "Toggle Tabs Beside Chat isn't available in this chat.")
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
}
