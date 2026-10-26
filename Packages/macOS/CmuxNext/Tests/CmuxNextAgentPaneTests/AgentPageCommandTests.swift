import CmuxNextActions
import Testing
@testable import CmuxNextAgentPane

/// The chat header's toggles in the palette (``AgentPageCommand``): available only where the page
/// lists them, honest about why not, and never run by automation that did not ask for focus.
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
        #expect(registry.bindAgentPageCommands(available: { [] }, run: { _, _ in }))
    }

    @Test func aCommandThePageDoesNotOfferIsUnavailableWithItsReason() {
        let registry = ActionRegistry.standard()
        registry.context = ActionContext(rawValue: .max)
        var ran: [AgentPageCommand] = []
        registry.bindAgentPageCommands(available: { ["toggleSideTabs"] }, run: { command, _ in ran.append(command) })
        #expect(registry.unavailableReason(for: "agentPane.toggleFiles") == "Toggle Files Beside Chat isn't available in this chat.")
        #expect(registry.unavailableReason(for: "agentPane.toggleSideTabs") == nil)
        registry.perform("agentPane.toggleFiles", invocation: ActionInvocation(origin: .cli, focusRequested: true))
        #expect(ran.isEmpty)
        registry.perform("agentPane.toggleSideTabs", invocation: ActionInvocation(origin: .cli, focusRequested: true))
        #expect(ran == [.toggleSideTabs])
    }

    @Test func automationMustRequestFocusBeforeRunningACommand() {
        let registry = ActionRegistry.standard()
        registry.context = ActionContext(rawValue: .max)
        var ran: [AgentPageCommand] = []
        registry.bindAgentPageCommands(available: { Set(AgentPageCommand.allCases.map(\.rawValue)) }, run: { command, _ in ran.append(command) })
        let refusal = registry.capturingRefusal {
            registry.perform("agentPane.togglePreview", invocation: ActionInvocation(origin: .cli))
        }
        #expect(refusal == "Toggle Preview Beside Chat requires focus.")
        #expect(ran.isEmpty)
        registry.perform("agentPane.togglePreview", invocation: ActionInvocation(origin: .cli, focusRequested: true))
        #expect(ran == [.togglePreview])
    }
}
