import CmuxNextPages
import CmuxNextSettings
import Foundation
import Testing
@testable import CmuxNextAgentPane

/// The header's right-click Customize saves its quick actions (`pane.setQuickActions`) through the
/// page host (Debug `agent.pageHost`) as it does through the old bridge: the op reaches the chat's
/// model instead of being refused as unknown. With no chat behind the provider, it reaches the
/// "closed" answer, past the op check.
@Suite
@MainActor
struct AgentPageHostQuickActionsTests {
    @Test func savingQuickActionsReachesTheChatThroughThePageHost() async throws {
        let provider = AgentPageProvider { _ in nil }
        let params: JSONValue = .object(["quickActions": .array([.object(["id": .string("browser"), "mode": .string("open")])])])
        do {
            _ = try await provider.call(AgentPageOps.namespace + "pane.setQuickActions", params: params, context: PageCallContext(page: PageDescriptor.agent.id))
            Issue.record("expected the closed answer with no chat behind the provider")
        } catch let error as PageError {
            #expect(error.code == PageError.closed.code)
        }
    }

    @Test func viewAllIsRegisteredOnTheRealAgentPageHost() async throws {
        let provider = AgentPageProvider { _ in nil }
        do {
            _ = try await provider.call(AgentPageOps.namespace + "chat.subagentList",
                                        params: .object([:]),
                                        context: PageCallContext(page: PageDescriptor.agent.id))
            Issue.record("expected the closed answer with no chat behind the provider")
        } catch let error as PageError {
            #expect(error.code == PageError.closed.code)
        }
    }
}
