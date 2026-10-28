import CmuxNextPages
import Foundation
import Testing
@testable import CmuxNextAgentPane
import CmuxNextSettings
import CmuxNextWakeups

/// A fresh page document starts with the web default, even when its native model did not change:
/// every page that loads again (a new host-events subscriber) must get the persisted composer settings.
@Suite(.serialized)
@MainActor
struct AgentPaneAttachmentViewReplayTests {
    private actor NoHost: AgentPaneHostProviding {
        func handshake(sessionId: String?) async throws -> AgentPaneHandshake { throw AgentPaneHostError.daemonStopped }
    }

    /// The `attachmentView` values the `composer` events carried, in order.
    private final class Received {
        var values: [String] = []
    }

    @Test func eachReadyRestoresThePersistedViewAfterTheDocumentResets() async throws {
        let file = try #require(AgentPageTestRoot.page)
        let view = try #require(AgentPaneView(mainThread: .standalone(), model: AgentPaneModel(host: NoHost()),
                                              work: BackgroundWork(label: "test.agent-pane"), source: .bundled(file),
                                              webUI: .agentPaneTestHost(), gestures: .testing()))
        defer { view.close() }
        var persisted = AgentPaneComposerSetting.fallback
        persisted.attachmentView = .strip
        persisted.push(to: view)
        #expect(view.model.composer.attachmentView == .strip)
        for _ in 0..<2 {
            // A reload clears only the page's state and subscribes again. The native setting stays
            // equal to the last push, so nothing is pushed: the subscription's replay must carry it.
            let received = Received()
            let subscription = try await view.pageEvents.subscribe(
                AgentPageProvider.hostEvents, filter: .null, context: PageCallContext(page: PageDescriptor.agent.id)
            ) { event in
                guard event["kind"] == .string("composer"), case .object(let value)? = event["value"],
                      case .string(let attachmentView)? = value["attachmentView"] else { return }
                received.values.append(attachmentView)
            }
            for _ in 0..<400 where received.values.isEmpty { await Task.yield() }
            subscription.cancel()
            #expect(received.values.last == "strip", "a page that loaded again starts with the web default attachment view")
        }
    }
}
