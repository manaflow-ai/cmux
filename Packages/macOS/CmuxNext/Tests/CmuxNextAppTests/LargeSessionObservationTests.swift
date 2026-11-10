@testable import CmuxNextAgentActivity
@testable import CmuxNextAgentLanes
import CmuxNextAgentPane
import CmuxNextBookmarks
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

    /// O4 `SidebarDocMachines.swift:132`: the sidebar's link favicons read every tab of the local store (its open tab
    /// favicon addresses, by origin) in one observation, so a navigation or a favicon change in any browser tab read
    /// every tab again, and posted `itemFaviconsChanged` also when nothing moved. Each workspace's open tab favicons are
    /// their own observation now; the follower reads their joined table.
    @Test(.timeLimit(.minutes(2)))
    func o4SidebarFaviconsObserveEachWorkspacesTabsOnTheirOwn() async throws {
        let fixture = LargeSessionFixture()
        let doc = SidebarDocStore(remote: nil)
        let byOrigin: @MainActor () -> [String: String] = { [store = fixture.store] in
            var found: [String: String] = [:]
            for tab in store.workspaces.flatMap(\.screens).flatMap(\.panes).flatMap(\.tabs) {
                if let favicon = Self.favicon(tab), found[favicon.origin] == nil { found[favicon.origin] = favicon.address }
            }
            return found
        }
        SidebarDocMachines.followFavicons(doc, revision: { nil }, byOrigin: byOrigin, faviconKey: BookmarkURL.faviconKey(for:))
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
        #expect(byOrigin()["http://127.0.0.1:9"] == "http://127.0.0.1:9/1/icon.png")
    }

    /// The fixture's open tab favicon: a browser tab's site origin and favicon address (the app also skips incognito tabs).
    static func favicon(_ tab: TabModel) -> (origin: String, address: String)? {
        guard tab.kind == .browser, let address = tab.faviconURL,
              let origin = tab.url.flatMap(URL.init(string:)).flatMap(BookmarkURL.faviconKey(for:)) else { return nil }
        return (origin, address)
    }
}
