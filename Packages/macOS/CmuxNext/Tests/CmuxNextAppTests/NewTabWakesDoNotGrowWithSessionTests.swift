import AppKit
@testable import CmuxNextApp
import CmuxNextBridge
import CmuxNextCompat
@testable import CmuxNextDaemon
import CmuxNextFocus
import Foundation
import Observation
import Testing

/// TERMINAL CREATE COST (lead, STATUS 13444): a local change costs O(changed items), never O(session). Under STRESS
/// (14 panes x 6 tabs) one New Terminal Tab woke about one observation per tab of the session, 9 ms of main-thread work
/// before the frame on cmux19. This counts the observation trackings one New Terminal Tab wakes (``ObservationWakes``:
/// `ObservationStream`, `SingleArmedTracking` and the Browser's `ObservationLoop`) in a whole window of 2 panes x 1 tab
/// and in one of 14 panes x 6 tabs, for the key's turn of New Terminal Tab: the stand-in tab in the store's intent log
/// (what `newSurface` does before it sends; every entrypoint shares it). The two counts must be equal: an observer that reads the whole session (the strip items, the sidebar, the
/// browser badge, Home, the browser tab list, the app services' watches, the workspace namer) makes the second larger.
@MainActor @Suite(.serialized)
struct NewTabWakesDoNotGrowWithSessionTests {
    /// Tab kinds of the STRESS session's panes (perf-stress-session.py: 2 terminals, 2 Chromium pages, 1 WebKit page,
    /// 1 agent chat): every kind of strip item is in the fixture, not terminals only.
    enum Mix { case terminals, stress }

    private static func tab(_ surface: UInt64, _ index: Int, mix: Mix) -> TabSnapshot {
        let id = SurfaceID(rawValue: surface)
        guard mix == .stress else { return TabSnapshot(surface: id, title: "~") }
        switch index % 6 {
        case 2, 3:
            return TabSnapshot(surface: id, kind: .browser, url: "http://127.0.0.1:9/\(surface)", browserRenderer: "frontend", browserEngine: "cef")
        case 4:
            return TabSnapshot(surface: id, kind: .browser, url: "http://127.0.0.1:9/\(surface)", browserRenderer: "frontend", browserEngine: "webkit")
        case 5:
            var chat = TabSnapshot(surface: id, kind: .conversation, title: "chat", browserRenderer: "frontend")
            chat.conversation = ConversationTabRef(agentSession: AgentSessionRef(host: "install:test", session: nil, harness: nil))
            return chat
        default:
            return TabSnapshot(surface: id, title: "~")
        }
    }

    private static func tree(panes: Int, tabs: Int, mix: Mix = .terminals) -> DaemonTree {
        var surface: UInt64 = 0
        let snapshots = (1...panes).map { pane in
            PaneSnapshot(id: PaneID(rawValue: UInt64(pane)), tabs: (0..<tabs).map { index in
                surface += 1
                return tab(surface, index, mix: mix)
            })
        }
        // A chain of splits to the right: every pane is shown on the one screen.
        let layout = snapshots.dropLast().reversed().reduce(LayoutNode.leaf(snapshots[snapshots.count - 1].id)) { rest, pane in
            .split(id: nil, resourceID: nil, direction: .right, ratio: 1.0 / Double(panes), a: .leaf(pane.id), b: rest)
        }
        let screen = ScreenSnapshot(id: ScreenID(rawValue: 1), layout: layout, panes: snapshots)
        var tree = DaemonTree(registryID: "s-local", workspaces: [
            WorkspaceSnapshot(id: WorkspaceHandle(rawValue: 1), key: WorkspaceKey(rawValue: "wakes-ws"), name: "wakes", screens: [screen]),
        ])
        tree.personal = PersonalState(workspaces: [PersonalWorkspace(sessionID: "s-local", workspaceKey: WorkspaceKey(rawValue: "wakes-ws"), index: 0)])
        return tree
    }

    /// Lets the main actor run what is queued: a fixed number of yields, no wait for time to pass.
    private static func drainMain() async {
        for _ in 0..<80 { await Task.yield() }
    }

    /// Runs `body` on a whole window showing `panes` panes of `tabs` tabs (its store and its content), then closes it.
    private static func withWindow<T>(panes: Int, tabs: Int, mix: Mix = .terminals,
                                      _ body: @MainActor (DaemonStore, WorkspaceContentController) async throws -> T) async throws -> T {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        AppActions.bind(services)
        services.windows.ordersWindowsIn = false
        let store = services.machines.local.store
        let identity = try JSONDecoder().decode(DaemonIdentity.self, from: Data(#"{"app":"cmux-tui","protocol":1,"session":"s-local","generation":"g1"}"#.utf8))
        store.noteHandshake(identity)
        store.connectionState = .connected(identity)
        store.apply(snapshot: tree(panes: panes, tabs: tabs, mix: mix))
        let controller = try #require(services.windows.openWindow(workspaces: ["wakes-ws"], frame: CGRect(x: 200, y: 200, width: 1600, height: 900)))
        defer { controller.teardown(); controller.window?.close() }
        for _ in 0..<50 where controller.workspaceContent?.panes.count != panes { await drainMain() }
        let content = try #require(controller.workspaceContent)
        try #require(content.panes.count == panes, "fixture: the window shows \(content.panes.count) of \(panes) panes")
        content.contentView.layoutSubtreeIfNeeded()
        await drainMain()
        return try await body(store, content)
    }

    /// The wakes of one New Terminal Tab on the first pane of a window showing `panes` panes of `tabs` tabs, by the
    /// `#fileID:#line` of each woken observer.
    private static func wakesOfNewTab(panes: Int, tabs: Int) async throws -> [String: Int] {
        try await withWindow(panes: panes, tabs: tabs) { store, content in
        let pane = try #require(content.panes.values.first { $0.pane.handle == PaneID(rawValue: 1) })
        let workspace = try #require(store.workspaces.first)
        @MainActor func tabCount() -> Int { workspace.screens.flatMap(\.panes).reduce(0) { $0 + $1.tabs.count } }
        let before = tabCount()

        // The key's turn of New Terminal Tab: the stand-in tab in the store's intent log
        // (`NewTerminalTabCommand.intendNow`, the part before any send). The registry's `newSurface` stops before it in
        // a test: the offline store has no connection (`PaneController.newTerminalTab`'s guard).
        let wakes = ObservationWakes()
        ObservationWakes.$current.withValue(wakes) {
            store.intend(.createTab(pane: pane.pane.handle, provisional: ProvisionalTab().terminal(TerminalID.generate(), cwd: nil)),
                         transaction: ClientTransactionID.generate())
        }
        try #require(tabCount() == before + 1, "fixture: New Terminal Tab made \(tabCount() - before) tabs, not 1")
        return wakes.bySite
        }
    }

    /// How many tabs each woken observer reads, by site: every tab's title changes once, in turn, and each change counts
    /// for every observer instance it wakes. An observer's count is the number of tabs whose change wakes it (the tab
    /// registrations it holds); the largest instance of each site is kept.
    private static func tabsReadPerObserver(panes: Int, tabs: Int) async throws -> [String: Int] {
        try await withWindow(panes: panes, tabs: tabs) { store, _ in
            let models = try #require(store.workspaces.first).screens.flatMap(\.panes).flatMap(\.tabs)
            try #require(models.count == panes * tabs, "fixture: \(models.count) tabs, not \(panes * tabs)")
            var reads: [ObjectIdentifier: (site: String, tabs: Int)] = [:]
            for (index, tab) in models.enumerated() {
                let wakes = ObservationWakes()
                ObservationWakes.$current.withValue(wakes) { tab.title = "tab \(index)" }
                for (instance, site) in wakes.woken { reads[instance, default: (site, 0)].tabs += 1 }
                await drainMain() // the woken observers re-arm before the next tab changes
            }
            return reads.values.reduce(into: [:]) { $0[$1.site] = max($0[$1.site, default: 0], $1.tabs) }
        }
    }

    /// How many panes' tab lists each woken observer reads, by site: every pane gets one stand-in tab (the key's intent
    /// of New Terminal Tab), in turn, and each one counts for every observer instance it wakes. An observer's count is the
    /// number of panes whose new tab wakes it; the largest instance of each site is kept.
    private static func panesReadPerObserver(panes: Int, tabs: Int, mix: Mix = .terminals) async throws -> [String: Int] {
        try await withWindow(panes: panes, tabs: tabs, mix: mix) { store, _ in
            let models = try #require(store.workspaces.first).screens.flatMap(\.panes)
            try #require(models.count == panes, "fixture: \(models.count) panes, not \(panes)")
            var reads: [ObjectIdentifier: (site: String, panes: Int)] = [:]
            for pane in models {
                let wakes = ObservationWakes()
                ObservationWakes.$current.withValue(wakes) {
                    store.intend(.createTab(pane: pane.handle, provisional: ProvisionalTab().terminal(TerminalID.generate(), cwd: nil)),
                                 transaction: ClientTransactionID.generate())
                }
                for (instance, site) in wakes.woken { reads[instance, default: (site, 0)].panes += 1 }
                await drainMain() // the woken observers re-arm before the next pane changes
            }
            return reads.values.reduce(into: [:]) { $0[$1.site] = max($0[$1.site, default: 0], $1.panes) }
        }
    }

    @Test(.timeLimit(.minutes(2)))
    func oneNewTabWakesAsManyObserversInAStressSessionAsInASmallOne() async throws {
        let small = try await Self.wakesOfNewTab(panes: 2, tabs: 1)
        let stress = try await Self.wakesOfNewTab(panes: 14, tabs: 6)
        let (smallCount, stressCount) = (small.values.reduce(0, +), stress.values.reduce(0, +))
        // The observers that woke more often in the larger session: they read something every pane or tab shares.
        let grew = stress.filter { $0.value > small[$0.key, default: 0] }
            .sorted { $0.value - small[$0.key, default: 0] > $1.value - small[$1.key, default: 0] }
            .map { "\($0.key) \(small[$0.key, default: 0]) -> \($0.value)" }
        // Every count, also when the test passes: which observers one new tab wakes, at each size.
        for site in Set(small.keys).union(stress.keys).sorted() {
            print("wakes \(site): 2x1 \(small[site, default: 0]), 14x6 \(stress[site, default: 0])")
        }
        print("wakes total: 2x1 \(smallCount), 14x6 \(stressCount)")
        #expect(smallCount > 0, "fixture: the new tab woke no observer (the counter is not wired)")
        #expect(stressCount == smallCount,
                "one New Terminal Tab woke \(smallCount) observers with 2 panes x 1 tab and \(stressCount) with 14 panes x 6 tabs; grew: \(grew)")
    }

    /// The cost of a wake is the observer's re-evaluation, which cancels and re-registers every value it reads: an observer
    /// that reads every tab of the session costs O(session) each time it wakes, even when one wake is all a new tab makes
    /// (the profile of STRESS New Terminal Tab: 72 % of the 9 ms after the key turn is Observation re-tracking). With 6
    /// tabs in every pane, an observer that reads only what it shows reads as many tabs with 14 panes as with 2.
    /// One new tab writes one pane's tab list (`PaneModel.tabs`): an observer that reads every pane's list wakes for a new
    /// tab in any pane and then cancels and re-registers all of them (profile 823feba6: `PaneModel.tabs.modify` ->
    /// `ObservationRegistrar.Context.cancel`, 3 ms of the STRESS key turn). An observer that reads only the panes it shows
    /// wakes as often with 14 panes as with 2.
    @Test(.timeLimit(.minutes(3)))
    func noObserverReadsMorePanesInAStressSessionThanInASmallOne() async throws {
        let small = try await Self.panesReadPerObserver(panes: 2, tabs: 6)
        let stress = try await Self.panesReadPerObserver(panes: 14, tabs: 6)
        for site in Set(small.keys).union(stress.keys).sorted() {
            print("panes read \(site): 2x6 \(small[site, default: 0]), 14x6 \(stress[site, default: 0])")
        }
        let grew = stress.filter { $0.value > small[$0.key, default: 0] }.sorted { $0.value > $1.value }
            .map { "\($0.key) \(small[$0.key, default: 0]) -> \($0.value)" }
        #expect(!small.isEmpty, "fixture: no observer read a pane (the counter is not wired)")
        #expect(grew.isEmpty, "observers that a new tab in any of 14 panes wakes, against 2 (they read every pane's tabs): \(grew)")
    }

    /// The STRESS bench (09f3dcc4, cmux19): one New Terminal Tab woke 56 strip items (PaneController.swift:46), 62 browser
    /// record writers and 62 emulation watches: one per browser or chat tab of the session. A new tab in one pane must wake
    /// no observer of another pane's tabs, whatever their kind: per site, the observer instances one new tab wakes are as
    /// many with 14 panes as with 2.
    @Test(.timeLimit(.minutes(3)))
    func aNewTabWakesNoPerTabObserverOfOtherPanesInAMixedSession() async throws {
        let small = try await Self.instancesWokenByOneNewTab(panes: 2, tabs: 6, mix: .stress)
        let stress = try await Self.instancesWokenByOneNewTab(panes: 14, tabs: 6, mix: .stress)
        for site in Set(small.keys).union(stress.keys).sorted() {
            print("instances woken \(site): 2x6 \(small[site, default: 0]), 14x6 \(stress[site, default: 0])")
        }
        let grew = stress.filter { $0.value > small[$0.key, default: 0] }.sorted { $0.value > $1.value }
            .map { "\($0.key) \(small[$0.key, default: 0]) -> \($0.value)" }
        #expect(!small.isEmpty, "fixture: the new tab woke no observer (the counter is not wired)")
        #expect(grew.isEmpty, "per-site observer instances one new tab wakes, 2 x 6 against 14 x 6 (mixed tabs): \(grew)")
    }

    /// Names the reads of another pane's strip item that a new tab wakes (PaneController.tabItem, the 8 -> 56 site): each
    /// read a browser tab's and an agent chat tab's item makes is tracked on its own in pane 2 of a 14 x 6 mixed session,
    /// then New Terminal Tab's intent runs in pane 1. The whole item must not wake, and the woken reads name the cause.
    @Test(.timeLimit(.minutes(2)))
    func aNewTabInPaneOneWakesNoReadOfPaneTwosStripItems() async throws {
        let woken = try await Self.withWindow(panes: 14, tabs: 6, mix: .stress) { store, content in
            let services = content.services
            let workspace = try #require(store.workspaces.first)
            let pane2 = try #require(content.panes.values.first { $0.pane.handle == PaneID(rawValue: 2) })
            let pane1 = try #require(content.panes.values.first { $0.pane.handle == PaneID(rawValue: 1) })
            let browser = try #require(pane2.pane.tabs.first { $0.kind == .browser }, "fixture: pane 2 has a browser tab")
            let chat = try #require(pane2.pane.tabs.first { $0.agentSession != nil }, "fixture: pane 2 has a chat tab")
            let names = Mutex<[String]>([])
            @MainActor func track(_ name: String, _ read: @escaping @MainActor () -> Void) {
                withObservationTracking { read() } onChange: { names.withLock { $0.append(name) } }
            }
            for (kind, tab) in [("browser", browser), ("chat", chat)] {
                track("\(kind): whole item") { _ = pane2.tabItem(tab) }
                track("\(kind): focus kind") { _ = FocusTopology.Kind.of(tab) }
                track("\(kind): tab fields") { _ = (tab.title, tab.kind, tab.url, tab.faviconURL, tab.browserEngine, tab.agentSession, tab.page, tab.appTab, tab.tabGroup) }
                track("\(kind): titles") {
                    let titles = TabTitleResolver(services: services, workspace: workspace.handle)
                    _ = (titles.isNewTabPage(tab), titles.untitled(tab, fallback: "~"), titles.page(tab))
                }
                track("\(kind): chat workspace name") { _ = AgentChatTabTitle.workspaceName(workspace) }
                track("\(kind): restartsKeptTab") { _ = pane2.daemon.restartsKeptTab(tab) }
                track("\(kind): item mapping") {
                    _ = TabItemMapping.shared.item(tab, fallbackTitle: "~", isNewTabPage: false, restarting: false, harnessIcons: services.harnessIconLookup)
                }
                track("\(kind): user icon") {
                    var item = StripTabItem(id: StripTabID(tab.id), title: "~")
                    TabItemMapping.shared.applyUserIcon(tab, to: &item, asset: IconAssetImages.shared.tabIcon(owner: pane2.daemon))
                }
                track("\(kind): home unread") { _ = services.home.unreadConversations.isEmpty }
                track("\(kind): dormant") { _ = services.cache.dormantTabs.contains(tab.id) }
                track("\(kind): machine badge") { _ = services.machines.tabBadge(pane2.daemon.machineID) }
                track("\(kind): machine color name") { _ = services.machines.tabColorName(pane2.daemon.machineID, badge: "x") }
                track("\(kind): incognito of its workspace") { _ = services.windows.isIncognito(workspace: workspace) }
                track("\(kind): incognito by key") { _ = services.cache.browserTabs.isIncognitoTab(tab.id) }
                track("\(kind): profile badge") { _ = services.browserProfiles.tabBadge(for: tab, workspaceID: workspace.id, room: nil) }
                track("\(kind): title attention") { _ = services.cache.pageRequests.titleAttention.marks(tab, selected: false, in: services.cache) }
                track("\(kind): favicon") { _ = services.browserFavicon(key: tab.id, recordFavicon: tab.faviconURL, known: (tab, false)) }
                track("\(kind): live page") { _ = services.cache.existingBrowser(tab.id)?.tab.state }
            }
            store.intend(.createTab(pane: pane1.pane.handle, provisional: ProvisionalTab().terminal(TerminalID.generate(), cwd: nil)),
                         transaction: ClientTransactionID.generate())
            await Self.drainMain()
            return names.withLock { $0 }
        }
        print("woken reads of pane 2's strip items: \(woken)")
        #expect(woken.isEmpty, "a new tab in pane 1 woke these reads of pane 2's strip items (14 x 6, mixed): \(woken)")
    }

    /// The observer instances one New Terminal Tab (the key's intent) in pane 1 wakes, counted per site.
    private static func instancesWokenByOneNewTab(panes: Int, tabs: Int, mix: Mix) async throws -> [String: Int] {
        try await withWindow(panes: panes, tabs: tabs, mix: mix) { store, content in
            let pane = try #require(content.panes.values.first { $0.pane.handle == PaneID(rawValue: 1) })
            let wakes = ObservationWakes()
            ObservationWakes.$current.withValue(wakes) {
                store.intend(.createTab(pane: pane.pane.handle, provisional: ProvisionalTab().terminal(TerminalID.generate(), cwd: nil)),
                             transaction: ClientTransactionID.generate())
            }
            return wakes.woken.values.reduce(into: [:]) { $0[$1, default: 0] += 1 }
        }
    }

    @Test(.timeLimit(.minutes(3)))
    func noObserverReadsMoreTabsInAStressSessionThanInASmallOne() async throws {
        let small = try await Self.tabsReadPerObserver(panes: 2, tabs: 6)
        let stress = try await Self.tabsReadPerObserver(panes: 14, tabs: 6)
        for site in Set(small.keys).union(stress.keys).sorted() {
            print("tabs read \(site): 2x6 \(small[site, default: 0]), 14x6 \(stress[site, default: 0])")
        }
        let grew = stress.filter { $0.value > small[$0.key, default: 0] }.sorted { $0.value > $1.value }
            .map { "\($0.key) \(small[$0.key, default: 0]) -> \($0.value)" }
        #expect(!small.isEmpty, "fixture: no observer read a tab (the counter is not wired)")
        #expect(grew.isEmpty, "observers that read more tabs with 14 panes x 6 tabs than with 2 x 6 (they read the whole session): \(grew)")
    }
}
