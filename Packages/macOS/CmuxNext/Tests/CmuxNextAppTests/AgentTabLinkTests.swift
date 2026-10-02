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

    /// A link's session opens strict (its page refuses a session the daemon
    /// lacks) and its turn waits for the page: on the model once the view
    /// is made, handed over with the first handshake.
    @Test func aLinkedSessionTabIsStrictAndCarriesItsTurn() async throws {
        let store = AgentTabStore(tag: nil, registry: ActionRegistry.standard(), environment: Self.mock, linkScheme: "cmux-dev-x")
        let daemon = DaemonStore()
        let key = store.openLinked(session: "s-9", in: "a", of: daemon)
        #expect(store.session(of: key) == "s-9")
        #expect(store.tab(showing: "s-9") == key)
        store.revealTurn("t-3", in: key)
        #expect(store.pendingTurn(in: key) == "t-3")
        let view = try #require(store.view(for: key))
        #expect(view.model.sessionMustExist)
        #expect(view.model.pendingRevealTurn == "t-3")
        let handshake = try #require(await view.model.respond(to: .ready)["value"] as? [String: Any])
        #expect(handshake["revealTurn"] as? String == "t-3")
        #expect(store.pendingTurn(in: key) == nil)
        // A tab opened any other way is not strict.
        let plain = store.open(in: "a", of: daemon, session: "s-1")
        #expect(try #require(store.view(for: plain)).model.sessionMustExist == false)
        #expect(store.session(of: store.open(in: "a", of: daemon)) == nil)
        store.closePane("a")
        #expect(store.pendingTurn(in: key) == nil)
    }

    @Test func everyPageGetsTheLinkScheme() throws {
        let store = AgentTabStore(tag: nil, registry: ActionRegistry.standard(), environment: Self.mock, linkScheme: "cmux-dev-x")
        let key = store.open(in: "a", of: DaemonStore())
        let view = try #require(store.view(for: key))
        #expect(view.model.linkScheme == "cmux-dev-x")
        store.closePane("a")
    }
}
