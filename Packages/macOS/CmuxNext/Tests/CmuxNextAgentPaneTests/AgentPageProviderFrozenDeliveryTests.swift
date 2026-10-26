import CmuxNextPages
import CmuxNextSettings
import Foundation
import Testing
@testable import CmuxNextAgentPane

/// The agent page's host events are a transcript the page cannot read again (p13-webui-027): a
/// frozen page keeps every one of them, so the stream is `.ordered`, never a dropping policy.
@MainActor
@Suite struct AgentPageProviderFrozenDeliveryTests {
    @Test func hostEventsAreOrdered() async throws {
        let provider = AgentPageProvider { _ in nil }
        let subscription = try await provider.subscribe(AgentPageProvider.hostEvents, filter: .null,
                                                        context: PageCallContext(page: PageDescriptor.agent.id)) { _ in }
        #expect(subscription.frozenDelivery == .ordered)
        subscription.cancel()
        #expect(!provider.hasSubscribers)
    }
}
