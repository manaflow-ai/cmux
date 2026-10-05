import CmuxNextActions
import CmuxNextAgentPane
@testable import CmuxNextApp
import CmuxNextDaemon
import Foundation
import Testing

/// Agent chat tabs are workspace store tabs (cmux-tui/spec/commands.md, new-conversation-tab): the store owns
/// pane membership, order and the session; the app keeps only the page views.
@MainActor
struct AgentTabStoreTests {
    /// A new tab is a store `conversation` tab on this Mac's acpmux: its record names this host
    /// and the session, and nothing about its pane is kept in the app.
    @Test func openingATabCreatesAStoreTab() async throws {
        let fixture = try AgentTabFixture()
        let key = try await fixture.open(session: "s-1")
        #expect(fixture.creations.map(\.record) == [AgentSessionRef(host: AgentTabFixture.host, session: "s-1")])
        let tab = try #require(fixture.daemon.tab(id: key))
        #expect(tab.kind == .conversation && tab.agentSession?.session == "s-1")
        #expect(fixture.tabs.isAgentTab(key))
        #expect(!fixture.tabs.isAgentTab("tab_a"), "a terminal tab is not an agent tab")
    }

    /// R138 without a second owner: a tab the store restored (quit and relaunch) shows its
    /// recorded session on first show.
    @Test func aRestoredTabShowsItsRecordedSession() throws {
        let record = AgentSessionRef(host: AgentTabFixture.host, session: "s-7")
        let fixture = try AgentTabFixture(tree: [AgentTabFixture.tab(50, "tab_restored", record)])
        let view = try #require(fixture.tabs.view(for: "tab_restored"))
        #expect(view.model.sessionId == "s-7")
        #expect(fixture.tabs.session(of: "tab_restored") == "s-7")
    }

    /// Only the Mac whose acpmux runs the session attaches to it.
    @Test func aTabOfAnotherHostGetsNoView() throws {
        let record = AgentSessionRef(host: "install:other-mac", session: "s-7")
        let fixture = try AgentTabFixture(tree: [AgentTabFixture.tab(50, "tab_elsewhere", record)])
        #expect(fixture.tabs.isAgentTab("tab_elsewhere"))
        #expect(fixture.tabs.view(for: "tab_elsewhere") == nil)
    }

    /// The user changes the chat in a tab: a compare-and-swap from the session the store has.
    /// A change another device made first is refused (the registry says why) and the next
    /// change expects the store's session again.
    @Test func changingTheChatInATabIsACompareAndSwap() async throws {
        let fixture = try AgentTabFixture()
        let key = try await fixture.open(session: "s-1")
        let view = try #require(fixture.tabs.view(for: key))
        _ = await view.model.respond(to: .persistSession("s-2"))
        await ReopenClosedTabTests.settle { fixture.binds.count == 1 }
        #expect(fixture.binds.last?.session == "s-2" && fixture.bindExpectations.last == "s-1")
        await ReopenClosedTabTests.settle { !fixture.daemon.hasPendingIntents }
        #expect(fixture.daemon.tab(id: key)?.agentSession?.session == "s-2", "the store took it")
        fixture.bindAnswer = .conflict
        _ = await view.model.respond(to: .persistSession("s-3"))
        await ReopenClosedTabTests.settle { fixture.binds.count == 2 && !fixture.daemon.hasPendingIntents }
        #expect(fixture.bindExpectations.last == "s-2", "the next change expects the session the store took")
        #expect(fixture.daemon.tab(id: key)?.agentSession?.session == "s-2", "a refused change goes away")
    }

    /// A creation the store refuses rolls back visibly: the tab shown at once goes away and its
    /// view state with it.
    @Test func aRefusedCreationRemovesTheTabShownAtOnce() async throws {
        let fixture = try AgentTabFixture()
        fixture.holdCreate = { }
        fixture.tabs.create = { _, _, _, _ in throw DaemonError.notConnected }
        let pending = try fixture.tabs.open(in: 3, of: fixture.service, session: "s-1")
        #expect(fixture.shownAgentTabs.count == 1, "shown before the store answers")
        await #expect(throws: DaemonError.self) { _ = try await pending.value() }
        #expect(fixture.shownAgentTabs.isEmpty, "the refusal removes it")
        #expect(fixture.tabs.session(of: pending.key) == nil)
    }

    /// A pane whose daemon is not connected gets no tab: nothing is shown and nothing queues.
    @Test func aDisconnectedDaemonGetsNoTab() throws {
        let fixture = try AgentTabFixture()
        fixture.tabs.reachable = { _ in false }
        #expect(throws: AgentTabRefusal.self) { _ = try fixture.tabs.open(in: 3, of: fixture.service) }
        #expect(fixture.shownAgentTabs.isEmpty && fixture.creations.isEmpty)
    }

    /// Close on a tab the store is still creating closes the store's tab once it answers.
    @Test func closingATabBeingCreatedClosesItWhenTheStoreAnswers() async throws {
        let fixture = try AgentTabFixture()
        let (gate, release) = AsyncStream<Void>.makeStream()
        fixture.holdCreate = { for await _ in gate { return } }
        let pending = try fixture.tabs.open(in: 3, of: fixture.service)
        var closed: [String] = []
        #expect(fixture.tabs.closeWhenCreated(pending.key) { closed.append($0) })
        release.yield()
        let created = try await pending.value()
        #expect(closed == [created.key])
        #expect(!fixture.tabs.closeWhenCreated(created.key) { _ in }, "a created tab closes through the daemon")
    }

    @Test func aHostNameIsCleanedForTheStore() {
        #expect(AgentTabStore.displayName("Studio\u{0}\n") == "Studio")
        #expect(AgentTabStore.displayName(String(repeating: "é", count: 200))?.utf8.count ?? 0 <= 255)
        #expect(AgentTabStore.displayName(" \u{7} ") == nil)
    }

    /// A tab whose session runs on another Mac says so instead of showing an empty pane.
    @Test func aTabOfAnotherHostShowsWhereItRuns() throws {
        let record = AgentSessionRef(host: "install:other-mac", hostName: "Studio", session: "s-7")
        let fixture = try AgentTabFixture(tree: [AgentTabFixture.tab(50, "tab_elsewhere", record)])
        let notice = try #require(fixture.tabs.notice(for: "tab_elsewhere"))
        #expect(notice.message == RemoteStrings.agentTabElsewhere("Studio"))
        let unnamed = try AgentTabFixture(tree: [AgentTabFixture.tab(51, "tab_far", AgentSessionRef(host: "install:x", session: "s"))])
        #expect(unnamed.tabs.notice(for: "tab_far")?.message == RemoteStrings.agentTabElsewhereUnknown)
        #expect(fixture.tabs.notice(for: "tab_a") == nil, "a terminal tab gets no notice")
    }

    /// A new chat's session is written to the store once; the page reporting it again binds
    /// nothing more.
    @Test func aNewChatsSessionIsBoundOnce() async throws {
        let fixture = try AgentTabFixture()
        let key = try await fixture.open()
        let view = try #require(fixture.tabs.view(for: key))
        _ = await view.model.respond(to: .persistSession("s-2"))
        _ = await view.model.respond(to: .persistSession("s-2"))
        await ReopenClosedTabTests.settle { !fixture.binds.isEmpty && !fixture.daemon.hasPendingIntents }
        #expect(fixture.binds.map(\.key) == [key] && fixture.binds.map(\.session) == ["s-2"])
        #expect(fixture.tabs.session(of: key) == "s-2")
    }

    /// Resuming the same outside chat again shows the tab already resuming
    /// it, so acpmux never gets a second adopt for one chat; once that tab
    /// leaves the tree, a resume opens a new one.
    @Test func resumingTheSameChatTwiceReusesItsTab() async throws {
        let fixture = try AgentTabFixture()
        let chat = AgentPaneAdopt(harness: "claude", agentSessionId: "0a1b2c3d")
        #expect(fixture.tabs.tab(resuming: chat) == nil)
        let first = try await fixture.tabs.open(in: 3, of: fixture.service, adopt: chat).value().key
        #expect(fixture.tabs.tab(resuming: chat) == first)
        #expect(fixture.creations.last?.record.harness == "claude")
        #expect(fixture.tabs.tab(resuming: AgentPaneAdopt(harness: "codex", agentSessionId: "0a1b2c3d")) == nil, "the id is per harness")
        try fixture.remove(first)
        #expect(fixture.tabs.tab(resuming: chat) == nil)
    }

    /// The same idempotency key returns the same store tab (the import's crash replay).
    @Test func aRetriedCreationReturnsTheSameTab() async throws {
        let fixture = try AgentTabFixture()
        let first = try await fixture.open(session: "s-1", key: "agent-tab-import-local-agent:1")
        let again = try await fixture.open(session: "s-1", key: "agent-tab-import-local-agent:1")
        #expect(first == again && fixture.keys == [first])
    }
}

@MainActor
struct AgentTabLifecycleTests {
    /// A tab closed out of sight (the CLI, another client, its pane closing) lets its page go
    /// once its tree is live without it; a tree from a daemon that is away is not trusted.
    @Test func aTabTheStoreNoLongerListsLetsItsViewGo() async throws {
        let fixture = try AgentTabFixture()
        try AgentTabFixture.connect(fixture.daemon)
        let key = try await fixture.open(session: "s-1")
        _ = try #require(fixture.tabs.view(for: key))

        _ = fixture.daemon.apply(.disconnected(reason: "test"))
        try fixture.remove(key)
        await ReopenClosedTabTests.settle { false }
        fixture.tabs.releaseGoneTabs(in: fixture.daemon)
        #expect(fixture.tabs.existingView(key) != nil, "a daemon that is away keeps its tabs' views")

        try AgentTabFixture.connect(fixture.daemon)
        await ReopenClosedTabTests.settle { fixture.tabs.existingView(key) == nil }
        #expect(fixture.tabs.existingView(key) == nil)
    }

    /// A daemon without agent session tabs (an older remote machine) gets no tab and nothing is
    /// sent; the refusal carries the localized reason.
    @Test func aDaemonWithoutAgentTabsIsRefused() async throws {
        let fixture = try AgentTabFixture()
        fixture.tabs.holdsTabs = { _ in false }
        #expect(!fixture.tabs.canHost(on: fixture.service))
        await #expect(throws: AgentTabRefusal.self) { _ = try await fixture.open() }
        #expect(fixture.creations.isEmpty)
    }

    /// A close this client sent releases the page only once the tree drops the tab: a failed
    /// close leaves the tab, and its page, in place.
    @Test func aCloseReleasesThePageOnlyWhenTheTreeDropsTheTab() async throws {
        let fixture = try AgentTabFixture()
        let key = try await fixture.open(session: "s-1")
        _ = try #require(fixture.tabs.view(for: key))
        fixture.tabs.releaseIfGone(key)
        #expect(fixture.tabs.existingView(key) != nil, "the tree still lists the tab")
        try fixture.remove(key)
        fixture.tabs.releaseIfGone(key)
        #expect(fixture.tabs.existingView(key) == nil)
    }

    /// Closing the tab (the cache's release) stops its page and forgets its view state.
    @Test func releasingATabForgetsItsViewState() async throws {
        let fixture = try AgentTabFixture()
        let key = try await fixture.open(session: "s-1", linked: true)
        fixture.tabs.revealTurn("t-1", in: key)
        fixture.tabs.release(key)
        #expect(fixture.tabs.existingView(key) == nil)
        #expect(fixture.tabs.pendingTurn(in: key) == nil)
        #expect(fixture.tabs.session(of: key) == "s-1", "the store record still names the session")
    }

    /// Pages show the app's shortcuts as bound now: a rebind in Settings or
    /// cmux.json reaches a page that is already open.
    @Test func openPagesFollowShortcutRebinds() async throws {
        let registry = ActionRegistry.standard()
        let fixture = try AgentTabFixture(registry: registry)
        let key = try await fixture.open()
        let view = try #require(fixture.tabs.view(for: key))
        await ReopenClosedTabTests.settle { view.shortcuts.labels["agentPane.searchChats"] == "⌘K" }
        #expect(view.shortcuts.labels["agentPane.searchChats"] == "⌘K")
        registry.setShortcutOverride(Shortcut("j", modifiers: [.command, .option]), for: "agentPane.searchChats")
        await ReopenClosedTabTests.settle { view.shortcuts.labels["agentPane.searchChats"] == "⌥⌘J" }
        #expect(view.shortcuts.labels["agentPane.searchChats"] == "⌥⌘J")
        registry.setShortcutOverride(nil, for: "agentPane.searchChats")
        await ReopenClosedTabTests.settle { view.shortcuts.labels["agentPane.searchChats"] == nil }
        #expect(view.shortcuts.labels["agentPane.searchChats"] == nil, "an unbound action shows no shortcut")
        fixture.tabs.release(key)
    }
}

/// The one-time import of the agent tabs an older build recorded in the window document.
@MainActor
@Suite struct AgentTabImportTests {
    @Test func theImportEmptiesTheRecordsAndSelectsTheStoreTabs() {
        var document = WindowStateDocument(
            windows: [WindowRecord(id: "w1", workspaceKey: nil, selectedTabs: ["pane_p": "local-agent:one", "pane_q": "tab_x"])],
            legacyAgentTabs: ["pane_p": [AgentTabRecord(id: "local-agent:one", session: "s-1")],
                              "pane_q": [AgentTabRecord(id: "local-agent:two", session: "s-2")]]
        )
        let kept = ["pane_q": [AgentTabRecord(id: "local-agent:two", session: "s-2")]]
        AgentTabImport.finish(&document, imported: ["local-agent:one": "tab_new"], remaining: kept)
        #expect(document.legacyAgentTabs == kept, "a record the daemon refused stays for the next launch")
        #expect(document.windows[0].selectedTabs == ["pane_p": "tab_new", "pane_q": "tab_x"])
        AgentTabImport.finish(&document, imported: ["local-agent:two": "tab_two"], remaining: [:])
        #expect(document.legacyAgentTabs.isEmpty)
    }

    @Test func theDocumentWritesTheRecordsOnlyWhileItHasSome() throws {
        var document = WindowStateDocument()
        let empty = try #require(String(data: try JSONEncoder().encode(document), encoding: .utf8))
        #expect(!empty.contains("agent_tabs"))
        document.legacyAgentTabs["pane-a"] = [AgentTabRecord(id: "local-agent:one", session: "s-1")]
        let data = try JSONEncoder().encode(document)
        #expect(try JSONDecoder().decode(WindowStateDocument.self, from: data).legacyAgentTabs == document.legacyAgentTabs)
        let old = try JSONDecoder().decode(WindowStateDocument.self, from: Data(#"{"windows":[]}"#.utf8))
        #expect(old.legacyAgentTabs.isEmpty)
    }

    @Test func importKeysAreStablePerOldTab() {
        #expect(AgentTabImport.key(for: "local-agent:one") == AgentTabImport.key(for: "local-agent:one"))
        #expect(AgentTabImport.key(for: "local-agent:one") != AgentTabImport.key(for: "local-agent:two"))
    }
}
