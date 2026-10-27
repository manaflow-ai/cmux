import CmuxNextPages
import Foundation
import Testing
@testable import CmuxNextAgentPane

/// The page's handshake (`cmux.agent.handshake`, the old bridge's `ready`) marks
/// `agent_pane.handshake_start` then `agent_pane.handshake_end`: the agent-ready mark
/// bench-startup.py reads. The deleted bridge marked them; the page host's provider does now, and
/// only for the handshake.
@MainActor
struct AgentPageHandshakeMarksTests {
    private actor NoHost: AgentPaneHostProviding {
        func handshake(sessionId: String?) async throws -> AgentPaneHandshake { throw AgentPaneHostError.daemonStopped }
    }

    /// The marks one provider's timings received, in order.
    private final class Marks {
        var names: [String] = []
    }

    private func provider(_ marks: Marks) -> (AgentPageProvider, AgentPaneModel) {
        let model = AgentPaneModel(host: NoHost())
        let provider = AgentPageProvider(mainWork: AgentPaneMainThread.standalone().mainWork) { _ in model }
        let timings = AgentPaneLaunchTimings()
        timings.install { marks.names.append($0) }
        provider.launchTimings = timings
        return (provider, model)
    }

    private func call(_ provider: AgentPageProvider, _ method: String) async {
        // The host has no daemon, so the call fails after it ran; only the marks matter here.
        _ = try? await provider.call(AgentPageOps.namespace + method, params: .object([:]),
                                     context: PageCallContext(page: PageDescriptor.agent.id))
    }

    @Test func theHandshakeMarksItsStartThenItsEnd() async {
        let marks = Marks()
        let (provider, model) = provider(marks)
        await call(provider, "handshake")
        #expect(marks.names == ["agent_pane.handshake_start", "agent_pane.handshake_end"])
        _ = model
    }

    @Test func anotherCallMarksNothing() async {
        let marks = Marks()
        let (provider, model) = provider(marks)
        await call(provider, "pane.setQuickActions")
        await call(provider, "chat.missing")
        #expect(marks.names.isEmpty, "\(marks.names)")
        _ = model
    }
}
