import CmuxNextActions
import CmuxNextAgentPane
@testable import CmuxNextApp
import CmuxNextDaemon
import Foundation
import Testing

/// `cmux://session/<id>` links find the agent tab that shows the session,
/// and every agent page gets this build's link scheme.
@MainActor
@Suite struct AgentTabLinkTests {
    private static let mock = ["CMUX_NEXT_AGENT_PANE_MOCK": "1"]

    @Test func theTabShowingASessionIsFoundByIt() async throws {
        let store = AgentTabStore(tag: nil, registry: ActionRegistry.standard(), environment: Self.mock, linkScheme: "cmux-dev-x")
        let daemon = DaemonStore()
        let opened = store.open(in: "a", of: daemon, session: "s-1")
        let fresh = store.open(in: "b", of: daemon)
        #expect(store.tab(showing: "s-1") == opened)
        #expect(store.paneKey(listing: opened) == "a")
        #expect(store.paneKey(listing: fresh) == "b")
        #expect(store.tab(showing: "s-2") == nil)
        #expect(store.paneKey(listing: "local-agent:missing") == nil)
        // A chat that later reports its session is found by it too.
        let view = try #require(store.view(for: fresh))
        _ = await view.model.respond(to: .persistSession("s-2"))
        #expect(store.tab(showing: "s-2") == fresh)
        store.closePane("a")
        #expect(store.tab(showing: "s-1") == nil)
        store.closePane("b")
    }

    @Test func everyPageGetsTheLinkScheme() throws {
        let store = AgentTabStore(tag: nil, registry: ActionRegistry.standard(), environment: Self.mock, linkScheme: "cmux-dev-x")
        let key = store.open(in: "a", of: DaemonStore())
        let view = try #require(store.view(for: key))
        #expect(view.model.linkScheme == "cmux-dev-x")
        store.closePane("a")
    }
}
