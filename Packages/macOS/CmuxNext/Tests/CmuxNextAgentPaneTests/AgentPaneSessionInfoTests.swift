import CmuxNextActions
import CmuxNextPages
import CmuxNextSettings
import Testing
@testable import CmuxNextAgentPane

@Suite(.serialized)
@MainActor
struct AgentPaneSessionInfoTests {
    private actor NoHost: AgentPaneHostProviding {
        func handshake(sessionId: String?) async throws -> AgentPaneHandshake { throw AgentPaneHostError.daemonStopped }
    }

    private final class Received {
        var events: [JSONValue] = []
    }

    @Test func paletteSessionInfoReachesItsOwnPageCommand() async throws {
        let file = try #require(AgentPageTestRoot.page)
        let view = try #require(AgentPaneView(model: AgentPaneModel(host: NoHost(), sessionId: "session-a"), source: .bundled(file), pageHost: true))
        let received = Received()
        let provider = try #require(view.pageEvents)
        let subscription = try await provider.subscribe(
            AgentPageProvider.hostEvents, filter: .null, context: PageCallContext(page: PageDescriptor.agent.id)
        ) { event in received.events.append(event) }
        defer { subscription.cancel() }

        let registry = ActionRegistry.standard()
        registry.context = ActionContext(rawValue: .max)
        #expect(registry.bindAgentPaneSessionInfo { _ in view.toggleSessionInfo() })
        #expect(registry.perform("agentPane.toggleSessionInfo"))
        #expect(received.events.filter { $0["kind"] == .string("command") } == [
            AgentPageEvent.command("toggleSessionInfo").data,
        ])
    }

    @Test func automationMustRequestFocusBeforeTogglingSessionInfo() {
        let registry = ActionRegistry.standard()
        registry.context = ActionContext(rawValue: .max)
        var toggles = 0
        #expect(registry.bindAgentPaneSessionInfo { _ in toggles += 1 })
        let refusal = registry.capturingRefusal {
            registry.perform("agentPane.toggleSessionInfo", invocation: ActionInvocation(origin: .cli))
        }
        #expect(refusal != nil)
        #expect(toggles == 0)
        registry.perform("agentPane.toggleSessionInfo", invocation: ActionInvocation(origin: .cli, focusRequested: true))
        #expect(toggles == 1)
    }
}
