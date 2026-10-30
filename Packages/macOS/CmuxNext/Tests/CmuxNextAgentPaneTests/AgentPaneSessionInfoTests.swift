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

    @Test(.timeLimit(.minutes(1))) func paletteSessionInfoReachesItsOwnPageCommand() async throws {
        let file = try #require(AgentPageTestRoot.page)
        let view = try #require(AgentPaneView(model: AgentPaneModel(host: NoHost(), sessionId: "session-a"), source: .bundled(file), pageHost: true, testRoot: true))
        // Subscribing queues the replay and flushes it in a task, so a command published right
        // after arrives later: read the stream until it shows up (or the time limit cancels).
        let (events, sink) = AsyncStream.makeStream(of: JSONValue.self)
        let provider = try #require(view.pageEvents)
        let subscription = try await provider.subscribe(
            AgentPageProvider.hostEvents, filter: .null, context: PageCallContext(page: PageDescriptor.agent.id)
        ) { sink.yield($0) }
        defer { subscription.cancel() }

        let registry = ActionRegistry.standard()
        registry.context = ActionContext(rawValue: .max)
        #expect(registry.bindAgentPaneSessionInfo(isOn: { true }) { _ in view.toggleSessionInfo() })
        #expect(registry.perform("agentPane.toggleSessionInfo"))
        let command = AgentPageEvent.command("toggleSessionInfo").data
        var commands: [JSONValue] = []
        for await event in events where event["kind"] == .string("command") {
            commands.append(event)
            if event == command { break }
        }
        #expect(commands == [command])
    }

    @Test func automationMustRequestFocusBeforeTogglingSessionInfo() {
        let registry = ActionRegistry.standard()
        registry.context = ActionContext(rawValue: .max)
        var toggles = 0
        #expect(registry.bindAgentPaneSessionInfo(isOn: { true }) { _ in toggles += 1 })
        let refusal = registry.capturingRefusal {
            registry.perform("agentPane.toggleSessionInfo", invocation: ActionInvocation(origin: .cli))
        }
        #expect(refusal == "Opening Session Info requires focus.")
        #expect(toggles == 0)
        registry.perform("agentPane.toggleSessionInfo", invocation: ActionInvocation(origin: .cli, focusRequested: true))
        #expect(toggles == 1)
    }

    /// With `agent.inspector` off the page has no Session Info, so the action says so instead of
    /// reporting a toggle that changed nothing.
    @Test func sessionInfoTurnedOffRefusesInsteadOfToggling() {
        let registry = ActionRegistry.standard()
        registry.context = ActionContext(rawValue: .max)
        var toggles = 0
        #expect(registry.bindAgentPaneSessionInfo(isOn: { false }) { _ in toggles += 1 })
        let refusal = registry.capturingRefusal {
            registry.perform("agentPane.toggleSessionInfo", invocation: ActionInvocation(origin: .cli, focusRequested: true))
        }
        #expect(refusal == "Session Info is turned off in Settings.")
        #expect(toggles == 0)
    }
}
