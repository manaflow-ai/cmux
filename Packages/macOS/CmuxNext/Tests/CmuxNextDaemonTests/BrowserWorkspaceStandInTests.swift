import Foundation
import Testing
@testable import CmuxNextDaemon

/// A new browser workspace shown at the press (atomic-activation): the workspace and its page are a
/// stand-in (`Intent.createWorkspace` with a browser first tab), and `create-workspace {first_tab}`
/// runs behind it. That request takes no transaction, so the daemon's raw `tab-added` of the first
/// tab comes before the reply with nothing naming its create. Shown as it came, the stand-in's screen
/// gave way to the daemon's tab under the daemon's id before the app moved the page to it: the window
/// built a second page for that id and dropped the one the person saw load. The raw tab is the
/// create's guess: hidden, the stand-in showing, until the reply names it.
@MainActor
struct BrowserWorkspaceStandInTests {
    private static let basePane = PaneID(rawValue: 3)
    private static let baseKey = WorkspaceKey(rawValue: "00000000-0000-4000-8000-000000000001")
    private static let base = WorkspaceSnapshot(
        id: WorkspaceHandle(rawValue: 1), key: baseKey, name: "1",
        screens: [ScreenSnapshot(id: ScreenID(rawValue: 2), active: true, activePane: basePane, layout: .leaf(basePane),
                                 panes: [PaneSnapshot(id: basePane, tabs: [TabSnapshot(surface: SurfaceID(rawValue: 4))])])])
    private static let workspace = WorkspaceHandle(rawValue: 9), pane = PaneID(rawValue: 10), screen = ScreenID(rawValue: 11)

    private static func store() -> DaemonStore {
        let store = DaemonStore()
        store.apply(snapshot: DaemonTree(workspaceRevision: 1, workspaces: [base]))
        return store
    }

    /// The daemon's workspace for `key` as `create-workspace` leaves it before its first tab: one screen, one empty pane.
    private static func created(_ key: WorkspaceKey) -> WorkspaceSnapshot {
        WorkspaceSnapshot(id: workspace, key: key, name: "web",
                          screens: [ScreenSnapshot(id: screen, active: true, activePane: pane, layout: .leaf(pane),
                                                   panes: [PaneSnapshot(id: pane, tabs: [])])])
    }

    private static func browserAdded(_ surface: SurfaceID, engine: String, sequence: UInt64) -> DaemonEventEnvelope {
        let entity = TabSnapshot(surface: surface, tabResourceID: ResourceID(rawValue: "tab_\(surface.rawValue)"), kind: .browser,
                                 url: "https://example.com/", browserRenderer: "frontend", browserEngine: engine)
        return DaemonEventEnvelope(sequence: sequence, event: .tabAdded(TabDelta(
            workspace: workspace, screen: screen, pane: pane, surface: surface, index: 0, entity: entity, clientTransactionID: nil)))
    }

    @Test func theWorkspaceAndItsPageShowInTheIntentsTurn() throws {
        let store = Self.store()
        let key = WorkspaceKey.generate()
        let shown = BrowserWorkspaceStandIn(key: key, name: "web", url: "https://example.com/", engine: "cef", profile: nil, in: store)
        let model = try #require(store.workspace(id: key.rawValue), "no workspace in the press's turn")
        let tabs = model.screens.flatMap(\.panes).flatMap(\.tabs)
        #expect(tabs.map(\.id) == [shown.tab], "no frame shows it empty, and nothing but its page")
        #expect(tabs.first?.kind == .browser)
        #expect(tabs.first?.snapshot.url == "https://example.com/")
    }

    @Test func theDaemonsRawFirstTabKeepsTheStandInUntilTheReplyNamesIt() throws {
        let store = Self.store()
        let key = WorkspaceKey.generate()
        let shown = BrowserWorkspaceStandIn(key: key, name: "web", url: "https://example.com/", engine: "cef", profile: nil, in: store)
        let model = try #require(store.workspace(id: key.rawValue))
        func tabs() -> [String] { model.screens.flatMap(\.panes).flatMap(\.tabs).map(\.id) }

        store.apply(snapshot: DaemonTree(workspaceRevision: 2, workspaces: [Self.base, Self.created(key)]))
        #expect(store.workspace(id: key.rawValue) === model, "the daemon's workspace takes the same model over")
        #expect(tabs() == [shown.tab], "the stand-in shows until the daemon's tab")

        // The daemon's raw tab-added, before the reply: nothing names its create yet.
        let daemonSurface = SurfaceID(rawValue: 12)
        _ = store.apply(batch: [Self.browserAdded(daemonSurface, engine: "cef", sequence: 1)])
        #expect(tabs() == [shown.tab], "the raw tab took the stand-in's place before the page could move to it: \(tabs())")

        // The reply names the tab: the page moves to it in the turn it takes the stand-in's place.
        var moved: [SurfaceID] = []
        let landed = shown.confirmed(surface: daemonSurface, at: 1) { moved.append($0) }
        #expect(landed)
        #expect(moved == [daemonSurface], "the page did not move to the daemon's tab exactly once: \(moved)")
        #expect(model.screens.flatMap(\.panes).flatMap(\.tabs).map(\.surface) == [daemonSurface])
        #expect(store.mirrorViolations.isEmpty)
    }

    /// A tab of the other engine in the new workspace (a script racing the press) is not the stand-in's first tab.
    @Test func anotherEnginesTabIsNotTheStandInsFirstTab() throws {
        let store = Self.store()
        let key = WorkspaceKey.generate()
        let transaction = BrowserWorkspaceStandIn(key: key, name: "web", url: "https://example.com/", engine: "cef", profile: nil, in: store).transaction
        store.apply(snapshot: DaemonTree(workspaceRevision: 2, workspaces: [Self.base, Self.created(key)]))
        _ = store.apply(batch: [Self.browserAdded(SurfaceID(rawValue: 12), engine: "webkit", sequence: 1)])
        #expect(!store.intentLog.entries.contains { $0.transaction == transaction && $0.createdSurface != nil },
                "a WebKit tab was taken for the Chromium stand-in's first tab")
    }

    @Test func aRefusedCreateLeavesNothing() {
        let store = Self.store()
        let key = WorkspaceKey.generate()
        let shown = BrowserWorkspaceStandIn(key: key, name: "web", url: "https://example.com/", engine: "webkit", profile: nil, in: store)
        shown.failed()
        #expect(store.workspace(id: key.rawValue) == nil)
        #expect(store.workspaces.map(\.id) == [Self.baseKey.rawValue])
        #expect(store.mirrorViolations.isEmpty)
    }
}
