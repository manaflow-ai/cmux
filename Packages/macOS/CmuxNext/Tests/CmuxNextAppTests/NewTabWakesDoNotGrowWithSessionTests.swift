import AppKit
@testable import CmuxNextApp
import CmuxNextCompat
@testable import CmuxNextDaemon
import Foundation
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
    private static func tree(panes: Int, tabs: Int) -> DaemonTree {
        var surface: UInt64 = 0
        let snapshots = (1...panes).map { pane in
            PaneSnapshot(id: PaneID(rawValue: UInt64(pane)), tabs: (0..<tabs).map { _ in
                surface += 1
                return TabSnapshot(surface: SurfaceID(rawValue: surface), title: "~")
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

    /// The wakes of one New Terminal Tab on the first pane of a window showing `panes` panes of `tabs` tabs, by the
    /// `#fileID:#line` of each woken observer.
    private static func wakesOfNewTab(panes: Int, tabs: Int) async throws -> [String: Int] {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        AppActions.bind(services)
        services.windows.ordersWindowsIn = false
        let store = services.machines.local.store
        let identity = try JSONDecoder().decode(DaemonIdentity.self, from: Data(#"{"app":"cmux-tui","protocol":1,"session":"s-local","generation":"g1"}"#.utf8))
        store.noteHandshake(identity)
        store.connectionState = .connected(identity)
        store.apply(snapshot: tree(panes: panes, tabs: tabs))
        let controller = try #require(services.windows.openWindow(workspaces: ["wakes-ws"], frame: CGRect(x: 200, y: 200, width: 1600, height: 900)))
        defer { controller.teardown(); controller.window?.close() }
        for _ in 0..<50 where controller.workspaceContent?.panes.count != panes { await drainMain() }
        let content = try #require(controller.workspaceContent)
        try #require(content.panes.count == panes, "fixture: the window shows \(content.panes.count) of \(panes) panes")
        content.contentView.layoutSubtreeIfNeeded()
        await drainMain()
        let pane = try #require(content.panes.values.first { $0.pane.handle == PaneID(rawValue: 1) })
        let workspace = try #require(store.workspaces.first)
        func tabCount() -> Int { workspace.screens.flatMap(\.panes).reduce(0) { $0 + $1.tabs.count } }
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

    @Test(.timeLimit(.minutes(2)))
    func oneNewTabWakesAsManyObserversInAStressSessionAsInASmallOne() async throws {
        let small = try await Self.wakesOfNewTab(panes: 2, tabs: 1)
        let stress = try await Self.wakesOfNewTab(panes: 14, tabs: 6)
        let (smallCount, stressCount) = (small.values.reduce(0, +), stress.values.reduce(0, +))
        // The observers that woke more often in the larger session: they read something every pane or tab shares.
        let grew = stress.filter { $0.value > small[$0.key, default: 0] }
            .sorted { $0.value - small[$0.key, default: 0] > $1.value - small[$1.key, default: 0] }
            .map { "\($0.key) \(small[$0.key, default: 0]) -> \($0.value)" }
        #expect(smallCount > 0, "fixture: the new tab woke no observer (the counter is not wired)")
        #expect(stressCount == smallCount,
                "one New Terminal Tab woke \(smallCount) observers with 2 panes x 1 tab and \(stressCount) with 14 panes x 6 tabs; grew: \(grew)")
    }
}
