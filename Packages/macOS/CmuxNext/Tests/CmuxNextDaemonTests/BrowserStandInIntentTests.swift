import Foundation
import Testing
@testable import CmuxNextDaemon

/// A new browser tab's stand-in (PL-cef-tab, `PaneBrowserTabOpener.openStandIn`): `new-frontend-browser-tab`
/// takes no transaction, so the daemon's raw `tab-added` can arrive before the reply with nothing
/// naming its create. Shown as it came, the pane listed the daemon's tab BESIDE the stand-in until
/// the reply (two new tabs for one key). It stays hidden, the stand-in showing, until the reply
/// names it; then it takes the stand-in's place in one apply.
@MainActor
struct BrowserStandInIntentTests {
    private static let pane = PaneID(rawValue: 3)
    private static let baseKey = WorkspaceKey(rawValue: "00000000-0000-4000-8000-000000000001")
    private static let base = WorkspaceSnapshot(
        id: WorkspaceHandle(rawValue: 1), key: baseKey, name: "1",
        screens: [ScreenSnapshot(id: ScreenID(rawValue: 2), active: true, activePane: pane, layout: .leaf(pane),
                                 panes: [PaneSnapshot(id: pane, tabs: [TabSnapshot(surface: SurfaceID(rawValue: 4))])])])

    private static func store() -> DaemonStore {
        let store = DaemonStore()
        store.apply(snapshot: DaemonTree(workspaceRevision: 1, workspaces: [base]))
        return store
    }

    private static func tabs(_ store: DaemonStore) throws -> [SurfaceID] {
        try #require(store.workspace(id: baseKey.rawValue)?.screens.first?.panes.first).tabs.map(\.surface)
    }

    /// The stand-in's record, as `ProvisionalTab.browser(url:engine:profile:)` makes it.
    private static func standIn(_ provisional: ProvisionalTab, engine: String) -> TabSnapshot {
        TabSnapshot(surface: provisional.surface, tabResourceID: ResourceID(rawValue: provisional.id), kind: .browser,
                    url: "https://example.com/", browserRenderer: "frontend", browserEngine: engine)
    }

    private static func browserAdded(_ surface: SurfaceID, engine: String, sequence: UInt64) -> DaemonEventEnvelope {
        let entity = TabSnapshot(surface: surface, tabResourceID: ResourceID(rawValue: "tab_\(surface.rawValue)"), kind: .browser,
                                 url: "https://example.com/", browserRenderer: "frontend", browserEngine: engine)
        return DaemonEventEnvelope(sequence: sequence, event: .tabAdded(TabDelta(
            workspace: WorkspaceHandle(rawValue: 1), screen: ScreenID(rawValue: 2), pane: pane, surface: surface,
            index: 1, entity: entity, clientTransactionID: nil)))
    }

    @Test func standInShowsInItsPaneInTheIntentsTurn() throws {
        let store = Self.store()
        let provisional = ProvisionalTab()
        store.intend(.createTab(pane: Self.pane, provisional: Self.standIn(provisional, engine: "cef")), transaction: .generate())
        #expect(try Self.tabs(store) == [SurfaceID(rawValue: 4), provisional.surface])
    }

    @Test func daemonBrowserTabWaitsHiddenForTheReplyThenTakesTheStandInsPlace() throws {
        let store = Self.store()
        let provisional = ProvisionalTab(), transaction = ClientTransactionID.generate()
        store.intend(.createTab(pane: Self.pane, provisional: Self.standIn(provisional, engine: "cef")), transaction: transaction)
        _ = store.apply(batch: [Self.browserAdded(SurfaceID(rawValue: 7), engine: "cef", sequence: 1)])
        #expect(try Self.tabs(store) == [SurfaceID(rawValue: 4), provisional.surface], "one new tab: the stand-in, the daemon's hidden")
        ProvisionalTab.created(transaction, surface: SurfaceID(rawValue: 7), in: store)
        #expect(try Self.tabs(store) == [SurfaceID(rawValue: 4), SurfaceID(rawValue: 7)], "the daemon's tab in the stand-in's place")
        store.noteSettled(transaction, at: 1)
        #expect(try Self.tabs(store) == [SurfaceID(rawValue: 4), SurfaceID(rawValue: 7)])
        #expect(store.mirrorViolations.isEmpty)
    }

    /// A browser tab of the other engine (a script's `tab new-webkit` racing the key) is not the stand-in's.
    @Test func anotherEnginesBrowserTabShowsBesideTheStandIn() throws {
        let store = Self.store()
        let provisional = ProvisionalTab()
        store.intend(.createTab(pane: Self.pane, provisional: Self.standIn(provisional, engine: "cef")), transaction: .generate())
        _ = store.apply(batch: [Self.browserAdded(SurfaceID(rawValue: 7), engine: "webkit", sequence: 1)])
        #expect(Set(try Self.tabs(store)) == [SurfaceID(rawValue: 4), SurfaceID(rawValue: 7), provisional.surface])
    }

    @Test func refusedStandInLeavesNothing() throws {
        let store = Self.store()
        let transaction = ClientTransactionID.generate()
        store.intend(.createTab(pane: Self.pane, provisional: Self.standIn(ProvisionalTab(), engine: "webkit")), transaction: transaction)
        store.rejectIntent(transaction)
        #expect(try Self.tabs(store) == [SurfaceID(rawValue: 4)])
        #expect(store.mirrorViolations.isEmpty)
    }
}
