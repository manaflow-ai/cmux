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

    /// Subscribing queues the replay and flushes it in a task, so a command published right
    /// after arrives later: wait for it instead of reading the events at once.
    private final class Received {
        var events: [JSONValue] = []
        private var waiter: (command: JSONValue, continuation: CheckedContinuation<Void, Never>)?

        var commands: [JSONValue] { events.filter { $0["kind"] == .string("command") } }

        func append(_ event: JSONValue) {
            events.append(event)
            if let waiter, commands.contains(waiter.command) {
                self.waiter = nil
                waiter.continuation.resume()
            }
        }

        func waitFor(_ command: JSONValue) async {
            guard !commands.contains(command) else { return }
            await withCheckedContinuation { waiter = (command, $0) }
        }
    }

    @Test(.timeLimit(.minutes(1))) func paletteSessionInfoReachesItsOwnPageCommand() async throws {
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
        let command = AgentPageEvent.command("toggleSessionInfo").data
        await received.waitFor(command)
        #expect(received.commands == [command])
    }

    @Test func automationMustRequestFocusBeforeTogglingSessionInfo() {
        let registry = ActionRegistry.standard()
        registry.context = ActionContext(rawValue: .max)
        var toggles = 0
        #expect(registry.bindAgentPaneSessionInfo { _ in toggles += 1 })
        let refusal = registry.capturingRefusal {
            registry.perform("agentPane.toggleSessionInfo", invocation: ActionInvocation(origin: .cli))
        }
        #expect(refusal == "Opening Session Info requires focus.")
        #expect(toggles == 0)
        registry.perform("agentPane.toggleSessionInfo", invocation: ActionInvocation(origin: .cli, focusRequested: true))
        #expect(toggles == 1)
    }
}
