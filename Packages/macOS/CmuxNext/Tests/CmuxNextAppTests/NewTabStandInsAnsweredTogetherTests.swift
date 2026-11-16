import AppKit
import CmuxNextBridge
@testable import CmuxNextApp
@testable import CmuxNextDaemon
@testable import CmuxNextTabs
import CmuxNextTestSupport
import Foundation
import Testing

/// A held New Tab key: two stand-in tabs wait for their creations, and the newer one is selected. The store then
/// names the daemon's tab of each creation, and one snapshot lists both tabs. The pane's strip pairs a stand-in
/// with its tab only when one stand-in left and one tab arrived, so in this apply it pairs none. The pane must
/// still select the tab of the selected stand-in, and show it in that same apply: no other tab shows in between,
/// and the pane is not empty for a frame.
///
/// The second case adds an open of the pane that has no stand-in and no answer yet (a terminal tab, a duplicate).
/// The strip holds back a pane's new tabs for such an open, because one of them can be the open's own tab. The tab
/// of the selected stand-in is not: the store's record names its creation. The pane selects and shows it all the same.
/// The tab of the stand-in that is not selected stays held back for that open, as before.
///
/// In both cases each tab is in its stand-in's place in the strip, and no other tab of the strip moves.
///
/// One pane in a window with no daemon. The test has no wait: each step is one call, and the pane's own
/// observation of the store cannot run before the test's apply.
@Suite(.closesItsWindows)
@MainActor struct NewTabStandInsAnsweredTogetherTests {
    private static func tree(_ surfaces: [UInt64]) -> DaemonTree {
        let pane = PaneSnapshot(id: PaneID(rawValue: 1), tabs: surfaces.map { TabSnapshot(surface: SurfaceID(rawValue: $0), title: "~") })
        let screen = ScreenSnapshot(id: ScreenID(rawValue: 1), layout: .leaf(PaneID(rawValue: 1)), panes: [pane])
        return DaemonTree(workspaces: [WorkspaceSnapshot(id: WorkspaceHandle(rawValue: 1), key: nil, name: "w1", screens: [screen])])
    }

    private static func connected() throws -> DaemonIdentity {
        let json = #"{"app":"cmux-tui","protocol":1,"session":"stand-ins-answered-together-test","generation":"g1"}"#
        return try JSONDecoder().decode(DaemonIdentity.self, from: Data(json.utf8))
    }

    /// A New Tab key in `pane`: its stand-in tab (a New Tab page) shows and is selected at once. Returns the
    /// stand-in's tab id and its creation's transaction.
    private static func newTab(in pane: PaneController, store: DaemonStore) -> (id: String, transaction: ClientTransactionID) {
        let provisional = ProvisionalTab()
        var page = TabSnapshot(surface: provisional.surface, tabResourceID: ResourceID(rawValue: provisional.id),
                               kind: .conversation, title: "about:blank", browserRenderer: "frontend")
        page.conversation = ConversationTabRef(agentSession: AgentSessionRef(host: "install:test", session: nil, harness: nil))
        let transaction = ClientTransactionID.generate()
        store.intend(.createTab(pane: pane.pane.handle, provisional: page), transaction: transaction)
        pane.selectWhenReported(surface: provisional.surface)
        return (provisional.id, transaction)
    }

    @Test(arguments: [false, true])
    func theTabOfTheSelectedStandInIsSelectedAndShownInTheApplyThatAnswersTwo(anotherOpenWaits: Bool) throws {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        let store = services.daemon.store
        store.connectionState = .connected(try Self.connected())
        store.apply(snapshot: Self.tree([1, 2]))
        let model = try #require(store.workspaces.first?.screens.first?.panes.first)
        let record = try JSONDecoder().decode(WindowRecord.self, from: Data(#"{"id":"w1","workspace_key":"w1"}"#.utf8))
        let state = WindowState(record: record)
        let pane = PaneController(pane: model, daemon: services.daemon, layoutPaneID: LayoutPaneID(model.id), services: services, state: state)
        defer { pane.teardown() }
        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 900, height: 300), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        pane.view.frame = NSRect(x: 0, y: 0, width: 900, height: 300)
        window.contentView = pane.view
        window.orderFrontRegardless()
        pane.syncStripFromStore()
        pane.view.layoutSubtreeIfNeeded()

        // Two New Tab keys: the strip lists both stand-ins, and the pane selects and shows the newer one.
        let first = Self.newTab(in: pane, store: store), second = Self.newTab(in: pane, store: store)
        let listed = pane.orderedIDs.map(\.rawValue)
        try #require(listed.contains(first.id) && listed.contains(second.id), "setup: the strip does not list both stand-ins: \(listed)")
        try #require(pane.stripModel.selectedID?.rawValue == second.id, "setup: the newer stand-in is not selected")
        try #require(pane.currentTabKey == second.id, "setup: the pane does not show the newer stand-in")
        if anotherOpenWaits {
            try #require(NewTabSuccession.begin(after: nil, in: model, services: services) != nil, "setup: the other open did not start")
        }

        // The store's record names the tab of each creation, and ONE snapshot lists both. No creator has heard of
        // its reply yet, so nothing but the pane's apply moves the selection.
        ProvisionalTab.created(first.transaction, surface: SurfaceID(rawValue: 3), in: store)
        ProvisionalTab.created(second.transaction, surface: SurfaceID(rawValue: 4), in: store)
        store.apply(snapshot: Self.tree([1, 2, 3, 4]))
        let made = try #require(store.tab(surface: SurfaceID(rawValue: 4)), "setup: the store has no tab for the newer creation")
        let older = try #require(store.tab(surface: SurfaceID(rawValue: 3)), "setup: the store has no tab for the older creation")
        let records = model.tabs.map(\.id)
        try #require(!records.contains(first.id) && !records.contains(second.id), "setup: a stand-in is still in the records: \(records)")
        try #require(pane.stripModel.selectedID?.rawValue == second.id, "setup: the pane applied the change before the test's apply")

        // The pane's ONE apply of that change.
        pane.syncStripFromStore()
        let selected = pane.stripModel.selectedID?.rawValue ?? "none", shown = pane.currentTabKey ?? "none"
        #expect(selected == made.id, "the pane selects \(selected), want the tab of the selected stand-in \(made.id); strip \(pane.orderedIDs.map(\.rawValue))")
        #expect(shown == made.id, "the pane shows \(shown) after the apply, want the tab of the selected stand-in \(made.id)")
        // Each tab is in its stand-in's place, and no other tab moved. The tab of the stand-in that is not selected is
        // held back while the other open has no answer.
        if anotherOpenWaits { try #require(NewTabSuccession.isOpen(in: model), "setup: the other open ended before the check") }
        let want: [String] = listed.compactMap { id -> String? in
            if id == second.id { return made.id }
            if id == first.id { return anotherOpenWaits ? nil : older.id }
            return id
        }
        let strip = pane.orderedIDs.map(\.rawValue)
        #expect(strip == want, "the strip lists \(strip), want \(want)")
    }
}
