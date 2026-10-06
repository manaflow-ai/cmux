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
    @Test func theTabShowingASessionIsFoundByIt() async throws {
        let fixture = try AgentTabFixture(linkScheme: "cmux-dev-x")
        let store = fixture.tabs
        let opened = try await fixture.open(session: "s-1")
        let fresh = try await fixture.open()
        #expect(store.tab(showing: "s-1") == opened)
        #expect(store.tab(showing: "s-2") == nil)
        // A chat that later reports its session is found by it too, before the store echoes it.
        let view = try #require(store.view(for: fresh))
        _ = await view.model.respond(to: .persistSession("s-2"))
        #expect(store.tab(showing: "s-2") == fresh)
        try fixture.remove(opened)
        #expect(store.tab(showing: "s-1") == nil)
    }

    /// A link's session opens strict (its page refuses a session the daemon
    /// lacks) and its turn waits for the page: on the model once the view
    /// is made, handed over with the first handshake.
    @Test func aLinkedSessionTabIsStrictAndCarriesItsTurn() async throws {
        let fixture = try AgentTabFixture(linkScheme: "cmux-dev-x")
        let store = fixture.tabs
        let key = try await fixture.open(session: "s-9", linked: true)
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
        let plain = try await fixture.open(session: "s-1")
        #expect(try #require(store.view(for: plain)).model.sessionMustExist == false)
        #expect(store.session(of: try await fixture.open()) == nil)
    }

    @Test func everyPageGetsTheLinkScheme() async throws {
        let fixture = try AgentTabFixture(linkScheme: "cmux-dev-x")
        let key = try await fixture.open()
        let view = try #require(fixture.tabs.view(for: key))
        #expect(view.model.linkScheme == "cmux-dev-x")
        fixture.tabs.release(key)
    }
}

/// R81 zero wait: a new agent tab shows in the pane at once, before the store answers
/// (an intent on the store's log), and the store's tab replaces it without a second tab.
@MainActor
@Suite struct AgentTabZeroWaitTests {
    @Test func aNewTabShowsBeforeTheStoreAnswers() async throws {
        let fixture = try AgentTabFixture()
        let (gate, release) = AsyncStream<Void>.makeStream()
        fixture.holdCreate = { for await _ in gate { return } }
        let opening = Task { try await fixture.open() }
        await ReopenClosedTabTests.settle { !fixture.shownAgentTabs.isEmpty }
        #expect(fixture.shownAgentTabs.count == 1, "the tab shows before the store answers")
        release.yield()
        let key = try await opening.value
        #expect(fixture.shownAgentTabs.map(\.id) == [key], "the store's tab replaces the one shown at once")
    }
}
