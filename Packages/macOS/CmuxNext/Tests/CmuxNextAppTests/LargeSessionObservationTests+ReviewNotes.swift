import AppKit
import CmuxNextAgentPane
@testable import CmuxNextApp
import CmuxNextBridge
import CmuxNextCompat
@testable import CmuxNextDaemon
import CmuxNextLayout
import Foundation
import Testing

/// The open review notes of #40457 (O9) and #40484 (O4). No case here drains with a yield count: each waits (bounded,
/// ``LargeSessionFixture/until(_:)``) on the value it checks, and fails with a message when the value never comes.
extension LargeSessionFixture {
    /// ``workspacesWaking(_:changes:)`` with no yield count. `value` is a number that each change moves (the test's own
    /// read of what the change writes). A test-owned observer follows `value`; before the first change and after each
    /// one this waits (bounded) until that observer delivered the current value, and fails with a message when it
    /// never does. Why that is the signal: a change resumes every woken observer inside the change itself, the test's
    /// observer among them, and the main actor runs those jobs in the order they were queued; the wait ends in a
    /// later job, so each observer the change woke has read (and tracks) again by then. The same holds for the first
    /// value: observers started before this call have made their first read when the test's observer made its own.
    static func workspacesWaking(_ sitePrefix: String, changes: [(workspace: Int, change: @MainActor () -> Void)],
                                 observing value: @escaping @MainActor @Sendable () -> Int)
        async throws -> [ObjectIdentifier: (site: String, workspaces: Set<Int>)] {
        let seen = WaitHits()
        let observer = Task { for await next in ObservationStream({ value() }) { seen.names.insert("\(next)") } }
        defer { observer.cancel() }
        let first = value()
        await until { seen.names.contains("\(first)") }
        try #require(seen.names.contains("\(first)"), "fixture: the test's own observer never read its first value (\(first))")
        var woken: [ObjectIdentifier: (site: String, workspaces: Set<Int>)] = [:]
        for (workspace, change) in changes {
            let wakes = ObservationWakes()
            ObservationWakes.$current.withValue(wakes) { change() }
            for (instance, site) in wakes.woken where site.hasPrefix(sitePrefix) {
                woken[instance, default: (site, [])].workspaces.insert(workspace)
            }
            let next = value()
            try #require(!seen.names.contains("\(next)"), "fixture: the change of workspace \(workspace) did not move the observed value (\(next))")
            await until { seen.names.contains("\(next)") }
            try #require(seen.names.contains("\(next)"), "the change of workspace \(workspace) never reached the test's own observer (value \(next))")
        }
        return woken
    }
}

extension LargeSessionObservationTests {
    /// O9, the session transfer wait when its workspace has its chat tab ALREADY (the case
    /// `o9TransferWaitIsNotWokenByATabOfAnotherWorkspace` leaves out: it keys a workspace that has a terminal only).
    /// Two ways to that state: the workspace comes under the key with its chat tab in ONE `workspace-added` event (no
    /// later tab change to wake the wait: only the key's own cell, `StoreIndex.workspaceKeyWaits`, can), and the wait
    /// opens after the keyed workspace and its chat tab are listed (it must match at its first read).
    ///
    /// A third way does not exist: a listed workspace never gets its key in place. The key is the workspace's identity
    /// (`WorkspaceModel.identity`, the model's constant `id`), and every workspace event finds its workspace by the
    /// entity's identity (`DaemonStore+Events.swift`, `workspacesByID[WorkspaceModel.identity(delta.entity)]`), so a
    /// `workspace-changed` event whose entity has another key names another workspace and changes none.
    ///
    /// The ids of the workspace that comes (9 001, 9 999) are past the session's at both sizes (`real`: up to 8 262).
    @Test(.timeLimit(.minutes(2)), arguments: SessionFixtureSize.arms)
    func o9TransferWaitMatchesAWorkspaceThatHasItsChatTabAlready(size: SessionFixtureSize) async throws {
        let fixture = LargeSessionFixture(size)
        let store = fixture.store
        func wait(_ key: String, into found: WaitHits) -> Task<Void, Never> {
            Task {
                for await listed in ObservationStream({ store.listsConversationTab(inWorkspace: key) }) {
                    found.names.insert(listed ? "listed" : "not listed yet")
                    if listed { return }
                }
            }
        }

        // The workspace comes under the key with its chat tab, in one event (the way the daemon tells of a new workspace).
        let late = WaitHits()
        let lateWait = wait("o9-late-key", into: late)
        defer { lateWait.cancel() }
        // The wait's own first value: it read (and tracks) the key's cell before the workspace comes.
        await LargeSessionFixture.until { late.names.contains("not listed yet") }
        try #require(late.names == ["not listed yet"], "fixture: the wait did not read once before the workspace came: \(late.names)")
        var chat = TabSnapshot(surface: SurfaceID(rawValue: 9_999), tabResourceID: ResourceID(rawValue: "tab_o9"), kind: .conversation,
                               title: "o9", browserRenderer: "frontend")
        chat.conversation = ConversationTabRef(agentSession: AgentSessionRef(host: LargeSessionFixture.host, session: "s-o9", harness: nil))
        let pane = PaneSnapshot(id: PaneID(rawValue: 9_001), resourceID: ResourceID(rawValue: "pane_o9"), tabs: [chat])
        let screen = ScreenSnapshot(id: ScreenID(rawValue: 9_001), layout: .leaf(pane.id), panes: [pane])
        let entity = WorkspaceSnapshot(id: WorkspaceHandle(rawValue: 9_001), key: WorkspaceKey(rawValue: "o9-late-key"),
                                       resourceID: ResourceID(rawValue: "ws_o9"), name: "o9", screens: [screen])
        store.apply(.workspaceAdded(WorkspaceDelta(workspace: entity.id, index: nil, entity: entity,
                                                   workspaceRevision: store.workspaceRevision + 1)))
        try #require(store.workspace(key: WorkspaceKey(rawValue: "o9-late-key")) != nil, "fixture: the event did not list the workspace under its key")
        await LargeSessionFixture.until { late.names.contains("listed") }
        #expect(late.names.contains("listed"), "the transfer wait did not hear its workspace come with its chat tab in one event")

        // The wait opens when the keyed workspace and its chat tab are listed already: its first read matches.
        let early = WaitHits()
        let earlyWait = wait("o9-late-key", into: early)
        defer { earlyWait.cancel() }
        await LargeSessionFixture.until { !early.names.isEmpty }
        #expect(early.names == ["listed"], "a transfer wait opened after the chat tab came did not match at once: \(early.names)")
    }

    /// One normal and one secret workspace, each with one page that has a title and a favicon.
    static func incognitoPages(normal: WorkspaceKey, secret: WorkspaceKey) -> DaemonTree {
        let normalPage = TabSnapshot(surface: 1, kind: .browser, title: "normal title", url: "https://normal.example/a",
                                     faviconURL: "https://normal.example/icon.png")
        let secretPage = TabSnapshot(surface: 2, kind: .browser, title: "secret title", url: "https://secret.example/a",
                                     faviconURL: "https://secret.example/icon.png")
        let normalScreen = ScreenSnapshot(id: 1, layout: .leaf(1), panes: [PaneSnapshot(id: 1, tabs: [normalPage])])
        let secretScreen = ScreenSnapshot(id: 2, layout: .leaf(2), panes: [PaneSnapshot(id: 2, tabs: [secretPage])])
        return DaemonTree(workspaces: [
            WorkspaceSnapshot(id: 1, key: normal, name: "normal", screens: [normalScreen]),
            WorkspaceSnapshot(id: 2, key: secret, name: "secret", screens: [secretScreen]),
        ])
    }

    /// The app's one-shot open tab favicon reads (`openTabFaviconsByOrigin`, `siteFaviconAddress`: bookmarks, the
    /// omnibar, the new tab page) for the secret page: no entry, and the site's own `/favicon.ico` address.
    static func expectNoSecretFavicon(_ services: AppServices, _ state: String) {
        let table = services.openTabFaviconsByOrigin()
        #expect(table["https://normal.example"] == "https://normal.example/icon.png", "\(state): a normal window's page gives no favicon: \(table)")
        #expect(table["https://secret.example"] == nil, "\(state): an incognito page gave its favicon to the sidebar links")
        #expect(services.siteFaviconAddress(origin: "https://secret.example") == "https://secret.example/favicon.ico",
                "\(state): an incognito page gave its favicon address to a bookmark or the omnibar")
    }

    /// O4, the incognito guard on the states the claim test (`o4AnIncognitoWindowsPageGivesNoOpenTabFavicon`) leaves
    /// out. `WindowManager.isIncognito(workspace:)` has three sources; this covers the flag: a workspace its daemon
    /// flags ephemeral, which no window lists or claims.
    @Test func o4AnEphemeralWorkspacesPageGivesNoOpenTabFavicon() throws {
        let services = IncognitoSpaceTests.services()
        let secret = WorkspaceKey.generate()
        services.daemon.store.apply(snapshot: Self.incognitoPages(normal: .generate(), secret: secret))
        try #require(services.daemon.store.workspace(id: secret.rawValue)).applyState(ephemeral: true, status: nil, screenGroups: nil)
        Self.expectNoSecretFavicon(services, "ephemeral flag")
    }

    /// O4, the guard for a workspace an incognito window lists (the registry's own cell, no claim left), and after that
    /// window closes while the daemon still lists the workspace (`discarding`).
    @Test func o4AListedIncognitoWindowsPageGivesNoOpenTabFavicon() throws {
        let services = IncognitoSpaceTests.services()
        let secret = WorkspaceKey.generate()
        services.daemon.store.apply(snapshot: Self.incognitoPages(normal: .generate(), secret: secret))
        _ = services.windows.registry.apply {
            $0.markIncognito("w-secret")
            return $0.openWindow(id: "w-secret", workspaceIDs: [secret.rawValue])
        }
        try #require(services.windows.claims.pending[secret.rawValue] == nil, "fixture: the workspace is claimed, not listed")
        Self.expectNoSecretFavicon(services, "listed by an incognito window")
        _ = services.windows.registry.apply { $0.close("w-secret") }
        Self.expectNoSecretFavicon(services, "its incognito window closed")
    }

    /// O4, the observed path (`SidebarDocWiring.swift`: `OpenTabFavicons.start` over `AppServices.openTabFavicons(of:)`,
    /// whose table `SidebarDocMachines.followFavicons` stores on the link items). A workspace can be listed before it
    /// is known as incognito (issue #31039: the tree entry comes before the ephemeral flag). When the flag lands, the
    /// workspace's own observation must give its favicon back. The waits read the observed table itself.
    @Test(.timeLimit(.minutes(2)))
    func o4TheFollowedFaviconsDropAPageWhoseWorkspaceTurnsIncognito() async throws {
        let services = IncognitoSpaceTests.services()
        let secret = WorkspaceKey.generate()
        let openTabs = OpenTabFavicons()
        openTabs.start(workspaces: { [store = services.machines.local.store] in store.workspaces },
                       favicons: { [weak services] workspace in services?.openTabFavicons(of: workspace) ?? [] })
        services.daemon.store.apply(snapshot: Self.incognitoPages(normal: .generate(), secret: secret))
        await LargeSessionFixture.until { openTabs.byOrigin["https://secret.example"] != nil }
        try #require(openTabs.byOrigin == ["https://normal.example": "https://normal.example/icon.png",
                                           "https://secret.example": "https://secret.example/icon.png"],
                     "fixture: the followed table does not list both pages before the flag: \(openTabs.byOrigin)")

        try #require(services.daemon.store.workspace(id: secret.rawValue)).applyState(ephemeral: true, status: nil, screenGroups: nil)
        await LargeSessionFixture.until { openTabs.byOrigin["https://secret.example"] == nil }
        #expect(openTabs.byOrigin == ["https://normal.example": "https://normal.example/icon.png"],
                "the followed favicons kept a page whose workspace turned incognito: \(openTabs.byOrigin)")
    }

    /// O4, the other reader of every open tab's page and favicon: an agent reply link's site (`AgentReplySites.sites`,
    /// shown in any agent chat for a link of the same site). It must not read a page of an incognito window. The window
    /// here is the claim kind (no ephemeral flag), as in `o4AnIncognitoWindowsPageGivesNoOpenTabFavicon`.
    @Test func o4AnIncognitoWindowsPageGivesNoReplyLinkSite() throws {
        let services = IncognitoSpaceTests.services()
        let window = services.windows.newIncognitoWindow()
        let secret = WorkspaceKey(rawValue: try #require(services.windows.claims.pending.first { $0.value == window }?.key))
        services.daemon.store.apply(snapshot: Self.incognitoPages(normal: .generate(), secret: secret))
        let normalURL = try #require(URL(string: "https://normal.example/a"))
        let secretURL = try #require(URL(string: "https://secret.example/a"))
        let sites = AgentReplySites(services: services).sites(for: [normalURL, secretURL])
        #expect(sites[normalURL]?.title == "normal title", "a normal window's page gives no reply link title: \(sites)")
        #expect(sites[secretURL] == nil, "an incognito window's page gave its title or favicon to a reply link: \(sites)")
    }
}
