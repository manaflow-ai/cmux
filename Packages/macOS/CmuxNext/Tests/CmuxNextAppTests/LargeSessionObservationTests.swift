@testable import CmuxNextAgentActivity
@testable import CmuxNextAgentLanes
import CmuxNextAgentPane
import CmuxNextBridge
import CmuxNextBrowser
import CmuxNextCompat
@testable import CmuxNextDaemon
import CmuxNextDesign
@testable import CmuxNextMobileHost
import CmuxNextSidebar
import Foundation
import Testing

/// The large session of plans/cmux-next/main-thread-scheduling.md 1.5, as a store fixture: 60 workspaces x 6 tabs
/// (per workspace one screen with two panes: 3 terminals in the first; 1 agent chat, 1 Chromium page and 1 WebKit page
/// in the second). Workspace `w` (1...60) is handle `w`, resource `ws_<w>`; its agent chat shows session `s-<w>` on
/// host ``host``. MTS-0 (step 0) owns the large session; this is the minimal fixture its row tests need.
@MainActor
struct LargeSessionFixture {
    static let workspaces = 60
    static let tabsPerWorkspace = 6
    /// `nonisolated`: ``tree()`` reads it in a local function of a closure, which is not on the main actor.
    nonisolated static let host = "install:large-session"

    let store: DaemonStore

    init() {
        store = DaemonStore()
        _ = store.apply(.connected(DaemonIdentity(generation: "large"), generationChanged: true))
        store.apply(snapshot: Self.tree())
    }

    nonisolated static func session(_ workspace: Int) -> String { "s-\(workspace)" }

    static func tree() -> DaemonTree {
        DaemonTree(workspaces: (1...workspaces).map { workspace in
            let base = UInt64(workspace) * 10
            func tab(_ index: Int) -> TabSnapshot {
                let surface = SurfaceID(rawValue: base + UInt64(index))
                let resource = ResourceID(rawValue: "tab_\(workspace)_\(index)")
                switch index {
                case 3:
                    var chat = TabSnapshot(surface: surface, tabResourceID: resource, kind: .conversation, title: "chat \(workspace)",
                                           browserRenderer: "frontend")
                    chat.conversation = ConversationTabRef(agentSession: AgentSessionRef(host: host, session: session(workspace), harness: nil))
                    return chat
                case 4:
                    return TabSnapshot(surface: surface, tabResourceID: resource, kind: .browser, url: "http://127.0.0.1:9/\(workspace)/cef",
                                       browserRenderer: "frontend", browserEngine: "cef")
                case 5:
                    return TabSnapshot(surface: surface, tabResourceID: resource, kind: .browser, url: "http://127.0.0.1:9/\(workspace)/webkit",
                                       browserRenderer: "frontend", browserEngine: "webkit")
                default:
                    return TabSnapshot(surface: surface, tabResourceID: resource, kind: .pty, title: "shell \(workspace).\(index)",
                                       cwd: "/tmp/large/\(workspace)")
                }
            }
            let terminals = PaneSnapshot(id: PaneID(rawValue: base + 1), resourceID: ResourceID(rawValue: "pane_\(workspace)_a"),
                                         tabs: (0..<3).map(tab))
            let pages = PaneSnapshot(id: PaneID(rawValue: base + 2), resourceID: ResourceID(rawValue: "pane_\(workspace)_b"),
                                     tabs: (3..<6).map(tab))
            let layout = LayoutNode.split(id: nil, resourceID: nil, direction: .right, ratio: 0.5, a: .leaf(terminals.id), b: .leaf(pages.id))
            let screen = ScreenSnapshot(id: ScreenID(rawValue: UInt64(workspace)), layout: layout, panes: [terminals, pages])
            return WorkspaceSnapshot(id: WorkspaceHandle(rawValue: UInt64(workspace)), key: nil,
                                     resourceID: ResourceID(rawValue: "ws_\(workspace)"), name: "w\(workspace)", screens: [screen])
        })
    }

    /// Each workspace's tabs, by workspace number (1...60).
    func tabs() -> [(workspace: Int, tab: TabModel)] {
        store.workspaces.enumerated().flatMap { offset, workspace in
            workspace.screens.flatMap(\.panes).flatMap(\.tabs).map { (offset + 1, $0) }
        }
    }

    /// Lets the main actor run what is queued: a fixed number of yields, no wait for time to pass.
    static func drainMain() async {
        for _ in 0..<80 { await Task.yield() }
    }

    /// Waits (polling the main actor, at most 10 s) until `condition` holds.
    static func until(_ condition: () -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(10)
        while !condition(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(5)) }
    }

    /// Changes each of `changes` in turn (one tab each, by workspace), and returns, for each observer instance whose site
    /// starts with `sitePrefix`, its site and the workspaces whose change woke it. The woken observers re-arm before the
    /// next change. An observer of one item is woken from one workspace at most (main-thread-scheduling.md 1.5 (c)).
    static func workspacesWaking(_ sitePrefix: String, changes: [(workspace: Int, change: @MainActor () -> Void)])
        async -> [ObjectIdentifier: (site: String, workspaces: Set<Int>)] {
        var woken: [ObjectIdentifier: (site: String, workspaces: Set<Int>)] = [:]
        for (workspace, change) in changes {
            let wakes = ObservationWakes()
            ObservationWakes.$current.withValue(wakes) { change() }
            for (instance, site) in wakes.woken where site.hasPrefix(sitePrefix) {
                woken[instance, default: (site, [])].workspaces.insert(workspace)
            }
            await drainMain()
        }
        return woken
    }
}

/// main-thread-scheduling.md 1.5 and section 3 (step 4): one observation per item, never one over every workspace and
/// tab. Each case starts one row's real observer over ``LargeSessionFixture``, changes the field it reads in one tab of
/// each workspace in turn (``ObservationWakes``), and checks that (b) one tab's change wakes only that row's item and
/// (c) no observer of the row is woken from more than one workspace. Deterministic: no GUI, no timing.
@MainActor @Suite(.serialized)
struct LargeSessionObservationTests {
    /// O2 `SidebarSessionTreeFeed.swift:59`: the session tree's pass walked every workspace, screen, pane and tab in one
    /// observation, so an agent chat's session change in any workspace ran the whole pass under tracking again. Each
    /// workspace's chats are their own observation now; the pass reads their joined list, never a tab.
    @Test(.timeLimit(.minutes(2)))
    func o2SessionTreeObservesEachWorkspacesChatsOnItsOwn() async throws {
        let fixture = LargeSessionFixture()
        let saved = DesignSettings.shared.sidebarSections
        DesignSettings.shared.sidebarSections.sessionTree = true
        defer { DesignSettings.shared.sidebarSections = saved }
        let tree = SidebarSessionTree(defaults: UserDefaults(suiteName: "large-session-o2-\(UUID().uuidString)")!)
        let feed = SidebarSessionTreeFeed(recordedParents: AgentSessionParents(defaults: nil))
        feed.start(workspaces: { [store = fixture.store] in store.workspaces }, localHost: LargeSessionFixture.host,
                   lanes: AgentLaneStore(), remote: RemoteAgentSessionLinks(), tree: tree)
        await LargeSessionFixture.until { tree.state != nil && feed.workspaces(showing: ["s-60"]).count == 1 }
        try #require(tree.state != nil, "fixture: the session tree published no state")
        let shown = feed.workspaces(showing: Set((1...LargeSessionFixture.workspaces).map(LargeSessionFixture.session)))
        try #require(shown.count == LargeSessionFixture.workspaces, "fixture: the feed found \(shown.count) of 60 agent chats")

        // The probe: each workspace's agent chat moves to a new session (what the pass reads of a tab).
        let chats = fixture.tabs().filter { $0.tab.kind == .conversation }
        try #require(chats.count == LargeSessionFixture.workspaces)
        let changes = chats.map { item -> (workspace: Int, change: @MainActor () -> Void) in
            let moved = AgentSessionRef(host: LargeSessionFixture.host, session: "\(LargeSessionFixture.session(item.workspace))-moved", harness: nil)
            return (item.workspace, { item.tab.conversation = ConversationTabRef(agentSession: moved) })
        }
        let woken = await LargeSessionFixture.workspacesWaking("CmuxNextAgentLanes/SidebarSessionTreeFeed", changes: changes)
        #expect(!woken.isEmpty, "fixture: no session tree observer woke (the counter is not wired)")
        let wide = woken.values.filter { $0.workspaces.count > 1 }.map { "\($0.site) woken from \($0.workspaces.count) workspaces" }
        #expect(wide.isEmpty, "session tree observers woken by more than one workspace: \(wide)")

        // The tree still follows: the moved sessions are found, in their own workspaces.
        await LargeSessionFixture.until { feed.workspaces(showing: ["s-7-moved"]).count == 1 }
        let moved = feed.workspaces(showing: ["s-7-moved", "s-7"])
        #expect(moved == [SidebarWorkspaceID(fixture.store.workspaces[6].id): "s-7-moved"])
    }
    /// O3 `AttentionTabsWatch.swift:87`: Needs you's marked tabs walked every tab of every workspace (twice: the marks and
    /// the launch baseline) in one observation, so an agent's mark on any tab ran the whole walk under tracking again.
    /// Each workspace's marks are their own observation now; the watch observes only each machine's readiness and its
    /// workspace list.
    @Test(.timeLimit(.minutes(2)))
    func o3AttentionTabsObservesEachWorkspacesMarksOnItsOwn() async throws {
        let fixture = LargeSessionFixture()
        let store = fixture.store
        store.session.apply(.snapshot(SessionStateMirror()), in: store)
        let tabs = AgentPaneAttentionTabs()
        var changes = 0
        let watch = AttentionTabsWatch(tabs: tabs, machines: { [store] in [(machine: "local", store: store)] },
                                       onChange: { _, _ in changes += 1 })
        defer { withExtendedLifetime(watch) {} }
        await LargeSessionFixture.until { changes > 0 }
        try #require(changes > 0, "fixture: the watch never delivered")

        // The probe: an agent marks the first terminal of each workspace in turn (tab-attention-v1).
        func mark(_ workspace: Int) {
            let attention = TabAttention(reason: "Sign in \(workspace)", atMs: UInt64(1_000 + workspace),
                                         requestID: String(format: "%032llx", UInt64(workspace)))
            store.session.apply(.delta([.tab(ResourceID(rawValue: "tab_\(workspace)_0"), .init(attention: attention))]), in: store)
        }
        let probes = (1...LargeSessionFixture.workspaces).map { workspace -> (workspace: Int, change: @MainActor () -> Void) in
            (workspace, { mark(workspace) })
        }
        let woken = await LargeSessionFixture.workspacesWaking("CmuxNextAgentPane/AttentionTabsWatch", changes: probes)
        #expect(!woken.isEmpty, "fixture: no attention observer woke (the counter is not wired)")
        let wide = woken.values.filter { $0.workspaces.count > 1 }.map { "\($0.site) woken from \($0.workspaces.count) workspaces" }
        #expect(wide.isEmpty, "attention observers woken by more than one workspace: \(wide)")

        // The list still follows every mark, newest first.
        await LargeSessionFixture.until { tabs.items.count == LargeSessionFixture.workspaces }
        #expect(tabs.items.count == LargeSessionFixture.workspaces)
        #expect(tabs.items.first?.reason == "Sign in 60")
    }
    /// O6 `SidebarChatHistoryFeed.swift:44`: the session tree's chat history read every live tab's agent session (and its
    /// lane's chat) in one observation, so an agent chat's session change in any workspace ran the whole history pass
    /// again. Each live tab's chat is its own observation now; the history reads their joined set.
    @Test(.timeLimit(.minutes(2)))
    func o6ChatHistoryObservesEachTabsChatOnItsOwn() async throws {
        let fixture = LargeSessionFixture()
        let saved = DesignSettings.shared.sidebarSections
        DesignSettings.shared.sidebarSections.sessionTree = true
        defer { DesignSettings.shared.sidebarSections = saved }
        let history = SidebarChatHistory(defaults: UserDefaults(suiteName: "large-session-o6-\(UUID().uuidString)")!)
        let feed = SidebarChatHistoryFeed()
        feed.start(liveTabs: { [store = fixture.store] in store.liveTabs }, localHost: LargeSessionFixture.host, open: { _ in },
                   windows: AcpmuxChatWindows(), lanes: AgentLaneStore(), history: history)
        await LargeSessionFixture.until { history.state != nil }
        try #require(history.state != nil, "fixture: the chat history published no state")

        let chats = fixture.tabs().filter { $0.tab.kind == .conversation }
        try #require(chats.count == LargeSessionFixture.workspaces)
        let changes = chats.map { item -> (workspace: Int, change: @MainActor () -> Void) in
            let moved = AgentSessionRef(host: LargeSessionFixture.host, session: "\(LargeSessionFixture.session(item.workspace))-moved", harness: nil)
            return (item.workspace, { item.tab.conversation = ConversationTabRef(agentSession: moved) })
        }
        let woken = await LargeSessionFixture.workspacesWaking("CmuxNextAgentLanes/SidebarChatHistoryFeed", changes: changes)
        #expect(!woken.isEmpty, "fixture: no chat history observer woke (the counter is not wired)")
        let wide = woken.values.filter { $0.workspaces.count > 1 }.map { "\($0.site) woken from \($0.workspaces.count) workspaces" }
        #expect(wide.isEmpty, "chat history observers woken by more than one workspace: \(wide)")
    }

    /// O4 `SidebarDocMachines.swift:132`: the sidebar's link favicons read every tab of the local store (its open tab
    /// favicon addresses, by origin) in one observation, so a navigation or a favicon change in any browser tab read
    /// every tab again, and posted `itemFaviconsChanged` also when nothing moved. Each workspace's open tab favicons are
    /// their own observation now; the follower reads their joined table.
    @Test(.timeLimit(.minutes(2)))
    func o4SidebarFaviconsObserveEachWorkspacesTabsOnTheirOwn() async throws {
        let fixture = LargeSessionFixture()
        let doc = SidebarDocStore(remote: nil)
        let openTabs = OpenTabFavicons()
        openTabs.start(workspaces: { [store = fixture.store] in store.workspaces }, favicon: { Self.favicon($0) })
        let byOrigin: @MainActor () -> [String: String] = { openTabs.byOrigin }
        SidebarDocMachines.followFavicons(doc, revision: { nil }, byOrigin: byOrigin, faviconKey: PageInfoSite.origin(of:))
        await LargeSessionFixture.drainMain()

        // The probe: each workspace's Chromium page gets its favicon (what the follower reads of a tab).
        let pages = fixture.tabs().filter { $0.tab.kind == .browser && $0.tab.url?.hasSuffix("/cef") == true }
        try #require(pages.count == LargeSessionFixture.workspaces)
        let changes = pages.map { item -> (workspace: Int, change: @MainActor () -> Void) in
            (item.workspace, { item.tab.faviconURL = "http://127.0.0.1:9/\(item.workspace)/icon.png" })
        }
        let woken = await LargeSessionFixture.workspacesWaking("CmuxNextBridge/", changes: changes)
        #expect(!woken.isEmpty, "fixture: no favicon observer woke (the counter is not wired)")
        let wide = woken.values.filter { $0.workspaces.count > 1 }.map { "\($0.site) woken from \($0.workspaces.count) workspaces" }
        #expect(wide.isEmpty, "favicon observers woken by more than one workspace: \(wide)")
        // The table still follows: the origin's first open tab (workspace 1) gives its favicon.
        await LargeSessionFixture.until { byOrigin()["http://127.0.0.1:9"] != nil }
        #expect(byOrigin()["http://127.0.0.1:9"] == "http://127.0.0.1:9/1/icon.png")
    }

    /// The fixture's open tab favicon: a browser tab's site origin and favicon address (the app also skips incognito tabs).
    static func favicon(_ tab: TabModel) -> OpenTabFavicons.Favicon? {
        guard tab.kind == .browser, let address = tab.faviconURL,
              let origin = tab.url.flatMap(URL.init(string:)).flatMap(PageInfoSite.origin(of:)) else { return nil }
        return OpenTabFavicons.Favicon(origin: origin, address: address)
    }

    /// O5 `IPhoneHostService.swift:374`: the folders acpmux gets for a phone's agent chats read every tab's `cwd` in one
    /// observation, so a `cd` in any terminal read every tab again (while iPhone access is on and signed in). Each
    /// workspace's folders are their own observation now; acpmux gets the joined list when it changed.
    @Test(.timeLimit(.minutes(2)))
    func o5IPhoneFoldersObserveEachWorkspacesTabsOnTheirOwn() async throws {
        let fixture = LargeSessionFixture()
        let folders = MobileHostWorkspaceFolders()
        var sent: [[String]] = []
        folders.follow({ [store = fixture.store] in store.workspaces }, send: { sent.append($0) })
        defer { folders.stop() }
        await LargeSessionFixture.until { sent.last?.count == LargeSessionFixture.workspaces }
        try #require(sent.last == (1...LargeSessionFixture.workspaces).map { "/tmp/large/\($0)" }, "fixture: \(sent.last ?? [])")

        // The probe: the first terminal of each workspace changes its folder (what the follower reads of a tab).
        let terminals = fixture.tabs().filter { $0.tab.resourceID?.rawValue.hasSuffix("_0") == true }
        try #require(terminals.count == LargeSessionFixture.workspaces)
        let changes = terminals.map { item -> (workspace: Int, change: @MainActor () -> Void) in
            (item.workspace, { item.tab.cwd = "/tmp/large/\(item.workspace)/src" })
        }
        let woken = await LargeSessionFixture.workspacesWaking("CmuxNextMobileHost/", changes: changes)
        #expect(!woken.isEmpty, "fixture: no folder observer woke (the counter is not wired)")
        let wide = woken.values.filter { $0.workspaces.count > 1 }.map { "\($0.site) woken from \($0.workspaces.count) workspaces" }
        #expect(wide.isEmpty, "folder observers woken by more than one workspace: \(wide)")
        // acpmux still follows: each workspace lists its new folder and its old one.
        await LargeSessionFixture.until { sent.last?.contains("/tmp/large/60/src") == true }
        #expect(sent.last?.contains("/tmp/large/7/src") == true)
        #expect(sent.last?.count == LargeSessionFixture.workspaces * 2)
    }

    /// O9, the waits until a match (`ChiefInspectorHandlers.swift:191`, `SessionTransferService.swift:258`,
    /// `HomeService+Workspace.swift:171`, `CloudMachineCreation.swift:421`; `DurableTabLink.swift:73` reads the index
    /// already): each re-ran a walk of every workspace (and its panes and tabs) on any change while it was open. Each
    /// reads the one id it waits for now: a change in another workspace wakes none, and the wait still ends when its
    /// tab or workspace comes. The probe writes the tab order and the key in place, which moves no store counter; in the
    /// app every tab add, move or close bumps `tabListRevision`, which the chief inspector and transfer waits still read
    /// (each such wake is O(1) or O(one workspace), not a walk). The home wait reads its own id's cell only.
    @Test(.timeLimit(.minutes(2)))
    func o9WaitsReadTheOneIDTheyWaitFor() async throws {
        let fixture = LargeSessionFixture()
        let store = fixture.store
        // A tab, a keyed workspace and a public workspace id no tree lists yet: the four waits stay open.
        let surface = SurfaceID(rawValue: 9_999)
        let found = WaitHits()
        func wait(_ name: String, _ lookup: @escaping @MainActor @Sendable () -> Bool) -> Task<Void, Never> {
            Task { for await hit in ObservationStream({ lookup() }) where hit { found.names.insert(name); return } }
        }
        let waits = [
            wait("chief inspector tab") { store.locatedTab(surface: surface) != nil },
            wait("transfer chat tab") { store.listsConversationTab(inWorkspace: "o9-key") },
            wait("home workspace") { store.listedWorkspace(resourceID: ResourceID(rawValue: "ws_o9")) != nil },
            wait("cloud workspace") { store.workspace(id: "o9-key") != nil },
        ]
        defer { waits.forEach { $0.cancel() } }
        await LargeSessionFixture.drainMain()
        #expect(found.names.isEmpty, "fixture: a wait matched before its tab or workspace came: \(found.names)")

        // The probe: each workspace gets a new public id the way the app sets one (a `workspace-changed` event:
        // `WorkspaceModel.update` writes `resourceID` in place and the store indexes the workspace again), moves its
        // terminals and gets a key (what the walks read of every workspace).
        let snapshots = LargeSessionFixture.tree().workspaces
        let changes = store.workspaces.enumerated().map { offset, workspace -> (workspace: Int, change: @MainActor () -> Void) in
            (offset + 1, {
                var entity = snapshots[offset]
                entity.resourceID = ResourceID(rawValue: "ws_\(offset + 1)-moved")
                store.apply(.workspaceChanged(WorkspaceDelta(workspace: entity.id, index: nil, entity: entity,
                                                             workspaceRevision: store.workspaceRevision + 1)))
                workspace.screens[0].panes[0].tabs.reverse()
                workspace.key = WorkspaceKey(rawValue: "k-\(offset + 1)")
            })
        }
        let woken = await LargeSessionFixture.workspacesWaking("CmuxNextAppTests/LargeSessionObservationTests", changes: changes)
        #expect(store.workspaces[6].resourceID == ResourceID(rawValue: "ws_7-moved"), "fixture: the event did not set the public id")
        let wide = woken.values.filter { $0.workspaces.count > 1 }.map { "\($0.site) woken from \($0.workspaces.count) workspaces" }
        #expect(wide.isEmpty, "waits woken by more than one workspace: \(wide)")

        // The tab and the workspace come (one apply): every wait ends.
        var tree = LargeSessionFixture.tree()
        var chat = TabSnapshot(surface: surface, tabResourceID: ResourceID(rawValue: "tab_o9"), kind: .conversation, title: "o9",
                               browserRenderer: "frontend")
        chat.conversation = ConversationTabRef(agentSession: AgentSessionRef(host: LargeSessionFixture.host, session: "s-o9", harness: nil))
        let pane = PaneSnapshot(id: PaneID(rawValue: 9_001), resourceID: ResourceID(rawValue: "pane_o9"), tabs: [chat])
        let screen = ScreenSnapshot(id: ScreenID(rawValue: 9_001), layout: .leaf(pane.id), panes: [pane])
        tree.workspaces.append(WorkspaceSnapshot(id: WorkspaceHandle(rawValue: 9_001), key: WorkspaceKey(rawValue: "o9-key"),
                                                 resourceID: ResourceID(rawValue: "ws_o9"), name: "o9", screens: [screen]))
        store.apply(snapshot: tree)
        await LargeSessionFixture.until { found.names.count == waits.count }
        #expect(found.names == ["chief inspector tab", "transfer chat tab", "home workspace", "cloud workspace"])
    }

    /// O9, the home wait (`HomeService+Workspace.swift:171`) when the tree lists its workspace already, under another
    /// public id: a `workspace-changed` event sets the id in place (`WorkspaceModel.update`) and the store indexes the
    /// workspace again under it. The set of workspaces does not change. The wait must end then (the base walk read every
    /// workspace's `resourceID` and heard it); it has no time limit, so a missed wake leaves the home unshown until
    /// the next connection. Red on 3622a166994: its `listedWorkspace(resourceID:)` read only `workspaces` and
    /// `workspaceSetRevision`, and neither changes.
    @Test(.timeLimit(.minutes(2)))
    func o9HomeWaitHearsAWorkspaceIndexedAgainUnderItsID() async throws {
        let fixture = LargeSessionFixture()
        let store = fixture.store
        let home = ResourceID(rawValue: "ws_o9-home")
        let found = WaitHits()
        let wait = Task {
            for await workspace in ObservationStream({ store.listedWorkspace(resourceID: home) }) where workspace != nil {
                found.names.insert("home workspace")
                return
            }
        }
        defer { wait.cancel() }
        await LargeSessionFixture.drainMain()
        #expect(found.names.isEmpty, "fixture: the home wait matched before its workspace came")

        var entity = LargeSessionFixture.tree().workspaces[6]
        entity.resourceID = home
        store.apply(.workspaceChanged(WorkspaceDelta(workspace: entity.id, index: nil, entity: entity,
                                                     workspaceRevision: store.workspaceRevision + 1)))
        try #require(store.workspaces[6].resourceID == home, "fixture: the event did not set workspace 7's public id")
        await LargeSessionFixture.until { !found.names.isEmpty }
        #expect(found.names == ["home workspace"], "the home wait did not hear workspace 7 indexed again under its id")
    }

    /// O7 `AgentLaneStore.swift:56`: every agent step writes the whole lane map (`lanes`), and the Needs You tray's
    /// approvals (`SidebarApprovals.followLanes`) read that map, so every step of any session re-ran it. It reads the
    /// waiting sessions (a set written only when it changes) and each waiting session's own cell now: a working
    /// agent's step wakes it from no other session.
    @Test(.timeLimit(.minutes(2)))
    func o7ApprovalsReadTheWaitingSessionsOnly() async throws {
        let saved = DesignSettings.shared.sidebarSections
        DesignSettings.shared.sidebarSections.sessionTree = true
        defer { DesignSettings.shared.sidebarSections = saved }
        let store = AgentLaneStore()
        let sessions = (1...LargeSessionFixture.workspaces).map(LargeSessionFixture.session)
        store.lanes = Dictionary(uniqueKeysWithValues: sessions.map { ($0, SidebarApprovalAnswerTests.lane($0, .working)) })
        let answerer = SidebarApprovalAnswerTests.Answerer()
        answerer.pending = ["s-7": SidebarApprovalAnswerTests.approval("s-7")]
        let approvals = SidebarApprovals(answerer: answerer)
        let following = approvals.followLanes(store)
        defer { following.cancel() }
        await LargeSessionFixture.drainMain()

        // The probe: each session's agent takes a step (what a working agent writes many times a second).
        let changes = sessions.enumerated().map { offset, session -> (workspace: Int, change: @MainActor () -> Void) in
            (offset + 1, {
                store.set(session, AgentActivityLane(id: session, name: session, title: session, peer: nil, parent: nil, state: .working,
                                                     since: nil, error: nil, workspaceID: nil, step: "step \(offset)"))
            })
        }
        let woken = await LargeSessionFixture.workspacesWaking("CmuxNextAgentLanes/SidebarApprovals", changes: changes)
        let wide = woken.values.filter { $0.workspaces.count > 1 }.map { "\($0.site) woken from \($0.workspaces.count) sessions" }
        #expect(wide.isEmpty, "approval observers woken by more than one session: \(wide)")

        // The tray still follows: a session that starts waiting gets its buttons.
        store.set("s-7", SidebarApprovalAnswerTests.lane("s-7", .input))
        await LargeSessionFixture.until { approvals.answerable["s-7"] != nil }
        #expect(approvals.answerable == ["s-7": "perm-s-7"])
    }
}

/// The waits of ``LargeSessionObservationTests/o9WaitsReadTheOneIDTheyWaitFor()`` that matched.
@MainActor final class WaitHits {
    var names = Set<String>()
}
