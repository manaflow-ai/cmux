@testable import CmuxNextAgentActivity
@testable import CmuxNextAgentLanes
import CmuxNextAgentPane
import CmuxNextBridge
import CmuxNextCompat
@testable import CmuxNextDaemon
import CmuxNextDesign
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
    static let host = "install:large-session"

    let store: DaemonStore

    init() {
        store = DaemonStore()
        _ = store.apply(.connected(DaemonIdentity(generation: "large"), generationChanged: true))
        store.apply(snapshot: Self.tree())
    }

    static func session(_ workspace: Int) -> String { "s-\(workspace)" }

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

    /// O9, the waits until a match (`ChiefInspectorHandlers.swift:191`, `SessionTransferService.swift:258`,
    /// `HomeService+Workspace.swift:171`, `CloudMachineCreation.swift:421`; `DurableTabLink.swift:73` reads the index
    /// already): each re-ran a walk of every workspace (and its panes and tabs) on any change while it was open. Each
    /// reads the one id it waits for now: a change in another workspace wakes none, and the wait still ends when its
    /// tab or workspace comes.
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

        // The probe: each workspace moves its terminals and gets a key (what the walks read of every workspace).
        let changes = store.workspaces.enumerated().map { offset, workspace -> (workspace: Int, change: @MainActor () -> Void) in
            (offset + 1, {
                workspace.screens[0].panes[0].tabs.reverse()
                workspace.key = WorkspaceKey(rawValue: "k-\(offset + 1)")
            })
        }
        let woken = await LargeSessionFixture.workspacesWaking("CmuxNextAppTests/LargeSessionObservationTests", changes: changes)
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
}

/// The waits of ``LargeSessionObservationTests/o9WaitsReadTheOneIDTheyWaitFor()`` that matched.
@MainActor final class WaitHits {
    var names = Set<String>()
}
