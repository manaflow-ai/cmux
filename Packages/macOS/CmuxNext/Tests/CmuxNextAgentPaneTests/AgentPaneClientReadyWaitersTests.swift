@testable import CmuxNextAgentPane
import Foundation
import Testing

/// Send to Chat on a chat whose page still connects (Fix on a failed command): the page action waits
/// for `pane.clientReady` instead of reaching a page that drops it.
@MainActor
struct AgentPaneClientReadyWaitersTests {
    private actor NoHost: AgentPaneHostProviding {
        func handshake(sessionId: String?) async throws -> AgentPaneHandshake { throw AgentPaneHostError.daemonStopped }
    }

    @Test func waitersRunOnceInOrderWhenThePageIsReady() async {
        let model = AgentPaneModel(host: NoHost())
        var ran: [Int] = []
        model.clientReadyWaiters = [{ ran.append(1) }, { ran.append(2) }]
        _ = await model.respond(to: .clientReady(false))
        #expect(ran.isEmpty)
        _ = await model.respond(to: .clientReady(true))
        #expect(ran == [1, 2])
        #expect(model.clientReadyWaiters.isEmpty)
        _ = await model.respond(to: .clientReady(true))
        #expect(ran == [1, 2])
    }
}
