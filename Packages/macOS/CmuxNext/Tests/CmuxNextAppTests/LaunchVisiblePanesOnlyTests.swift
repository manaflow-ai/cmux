import AppKit
import CmuxNextActions
import CmuxNextBridge
@testable import CmuxNextApp
@testable import CmuxNextDaemon
import CmuxNextFeatures
import CmuxNextWakeups
import CmuxNextWakeupsTestSupport
import Foundation
import Testing

/// Hidden workspaces and panes stay model-only at launch (`launchVisiblePanesOnly`):
/// a window of 60 workspaces builds the one it shows and nothing of the other 59; until startup
/// completes a pane the layout does not report on screen makes no content, one on screen does
/// (counted in `views_built`), one in the keep-alive band makes its content after completion, and
/// one away stays model-only until the layout brings it near.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1))) struct LaunchVisiblePanesOnlyTests {
    final class Provider: InternalPageProvider {
        let page = InternalPageID(rawValue: "launch-visible-panes-test")
        var title: String { "Notes" }
        var symbol: String { "doc" }
        func makeView(for key: String, in window: WindowController?) -> NSView { NSView() }
    }

    /// The app at launch with the feature on: its presentation and the launch's posts run on the same hand-run frames.
    @MainActor final class Launch {
        let scheduler = StartupTestScheduler()
        let services: AppServices

        init() throws {
            _ = NSApplication.shared
            let features = FeatureList(registry: FeatureRegistry(), channel: .dev,
                                       overrides: FeatureOverrides(environmentEnabled: [Feature.launchVisiblePanesOnly.name]))
            services = AppServices(environment: AppEnvironment.current([:]), mainWork: scheduler.mainWork,
                                   launchStartup: scheduler.startup, features: features)
            services.windows.ordersWindowsIn = false
            let identity = try JSONDecoder().decode(DaemonIdentity.self, from: Data(#"{"app":"cmux-tui","protocol":1,"session":"s-local","generation":"g1"}"#.utf8))
            services.daemon.store.noteHandshake(identity)
            services.daemon.store.connectionState = .connected(identity)
        }

        func frames(_ count: Int = 6) {
            for _ in 0..<count { scheduler.fire() }
        }

        func tearDown() {
            scheduler.startup.beginQuit()
            for controller in services.windows.controllers { controller.window?.close() }
        }
    }

    /// `count` workspaces of one terminal pane each, in sidebar order.
    private static func tree(workspaces count: Int) -> DaemonTree {
        let workspaces = (1...count).map { index -> WorkspaceSnapshot in
            let pane = PaneSnapshot(id: PaneID(rawValue: UInt64(index)), tabs: [TabSnapshot(surface: SurfaceID(rawValue: UInt64(index)), title: "~")])
            let screen = ScreenSnapshot(id: ScreenID(rawValue: UInt64(index)), layout: .leaf(pane.id), panes: [pane])
            return WorkspaceSnapshot(id: WorkspaceHandle(rawValue: UInt64(index)), key: WorkspaceKey(rawValue: "ws\(index)"), name: "ws\(index)", screens: [screen])
        }
        var tree = DaemonTree(registryID: "s-local", workspaces: workspaces)
        tree.personal = PersonalState(workspaces: (1...count).map {
            PersonalWorkspace(sessionID: "s-local", workspaceKey: WorkspaceKey(rawValue: "ws\($0)"), index: $0 - 1)
        })
        return tree
    }

    /// One workspace `split` of `count` terminal panes side by side.
    private static func splitTree(panes count: Int) -> DaemonTree {
        let panes = (1...count).map { index in
            PaneSnapshot(id: PaneID(rawValue: UInt64(index)), tabs: [TabSnapshot(surface: SurfaceID(rawValue: UInt64(index)), title: "~")])
        }
        let layout = panes.dropLast().reversed().reduce(LayoutNode.leaf(panes[count - 1].id)) { right, pane in
            .split(id: nil, resourceID: nil, direction: .right, ratio: 0.5, a: .leaf(pane.id), b: right)
        }
        let screen = ScreenSnapshot(id: ScreenID(rawValue: 1), layout: layout, panes: panes)
        var tree = DaemonTree(registryID: "s-local", workspaces: [
            WorkspaceSnapshot(id: WorkspaceHandle(rawValue: 1), key: WorkspaceKey(rawValue: "split"), name: "split", screens: [screen]),
        ])
        tree.personal = PersonalState(workspaces: [PersonalWorkspace(sessionID: "s-local", workspaceKey: WorkspaceKey(rawValue: "split"), index: 0)])
        return tree
    }

    /// A window showing workspace `split` with its `count` panes mounted by one layout pass; no frame has run.
    private static func splitWindow(panes count: Int, in launch: Launch) throws -> WorkspaceContentController {
        launch.services.daemon.store.apply(snapshot: splitTree(panes: count))
        let controller = try #require(launch.services.windows.openWindow(workspaces: ["split"], frame: CGRect(x: 200, y: 200, width: 1200, height: 760)))
        let content = try #require(controller.workspaceContent)
        content.contentView.layoutSubtreeIfNeeded()
        try #require(content.panes.count == count, "the window mounted \(content.panes.count) of the workspace's \(count) panes")
        return content
    }

    /// The pane's selected tab: the terminal whose cache entry is its content.
    private static func selectedKey(_ pane: PaneController) throws -> String {
        try #require(pane.stripModel.selectedID?.rawValue)
    }

    /// One pane outside a workspace with one page tab selected, as a restored pane before the layout
    /// reports where it is. The pane holds its window state weakly: the caller keeps it.
    private static func pane(in launch: Launch) throws -> (WindowState, PaneController, key: String) {
        let store = launch.services.daemon.store
        store.apply(snapshot: tree(workspaces: 1))
        let model = try #require(store.workspaces.first?.screens.first?.panes.first)
        let record = try JSONDecoder().decode(WindowRecord.self, from: Data(#"{"id":"w1","workspace_key":"ws1"}"#.utf8))
        let provider = Provider()
        launch.services.pages.register(provider)
        let state = WindowState(record: record)
        let pane = PaneController(pane: model, daemon: launch.services.daemon, layoutPaneID: LayoutPaneID(model.id),
                                  services: launch.services, state: state)
        let key = launch.services.pages.open(provider.page, in: pane.paneKey, of: store)
        pane.syncStripFromStore()
        pane.applySelection(StripTabID(key))
        return (state, pane, key)
    }

    /// Acceptance: 60 workspaces in one window build 1: no controller, pane or terminal for the 59 hidden ones,
    /// and the one pane shown makes its terminal, counted as the one view built.
    @Test func aWindowOfSixtyWorkspacesBuildsOnlyTheOneItShows() throws {
        let launch = try Launch()
        defer { launch.tearDown() }
        launch.services.daemon.store.apply(snapshot: Self.tree(workspaces: 60))
        let keys = (1...60).map { "ws\($0)" }
        let controller = try #require(launch.services.windows.openWindow(workspaces: keys, frame: CGRect(x: 200, y: 200, width: 1200, height: 760)))
        let shown = try #require(controller.workspaceContent)
        shown.contentView.layoutSubtreeIfNeeded()
        #expect(launch.services.windows.controllers.count == 1)
        #expect(keys.contains(shown.workspace.id))
        #expect(controller.parked.isEmpty, "hidden workspaces built controllers: \(controller.parked.keys.sorted())")
        #expect(shown.panes.count == 1, "the shown workspace mounted \(shown.panes.count) panes, not its one")
        let pane = try #require(shown.panes.values.first)
        pane.setPresence(.visible) // what the layout reports for the one pane on screen (a no-op when it did)
        launch.frames()
        #expect(launch.services.cache.existingTerminal(try Self.selectedKey(pane)) != nil, "the pane on screen made no terminal")
        #expect(launch.services.cache.liveTerminalCount == 1, "terminals made: \(launch.services.cache.liveTerminalCount), not the shown one only")
        #expect(launch.scheduler.startup.completion == nil)
        launch.scheduler.complete()
        #expect(launch.services.launchPanes.viewsBuilt == 1, "views built at completion: \(launch.services.launchPanes.viewsBuilt), not 1")
    }

    /// Focused first, then visible, and the keep-alive band after completion: of 3 panes, 2 on screen (one of them
    /// focused) and 1 in the keep-alive band, the focused one makes its terminal in the turn the layout reports it,
    /// the other on the next frame, and the third only after startup completes. views_built == the 2 visible panes.
    @Test func theFocusedPaneShowsFirstTheOtherVisibleNextAndTheKeepAliveOneAfterCompletion() throws {
        let launch = try Launch()
        defer { launch.tearDown() }
        let content = try Self.splitWindow(panes: 3, in: launch)
        let focused = try #require(content.focusedPane)
        let others = content.panes.values.filter { $0 !== focused }.sorted { $0.paneKey < $1.paneKey }
        try #require(others.count == 2)
        let (visible, keepAlive) = (others[0], others[1])
        let cache = launch.services.cache
        // What the layout reports (each call a no-op when it reported the same): two on screen, one just past it.
        focused.setPresence(.visible)
        visible.setPresence(.visible)
        keepAlive.setPresence(.keepAlive)
        #expect(cache.existingTerminal(try Self.selectedKey(focused)) != nil, "the focused pane did not show in the report's turn")
        #expect(cache.existingTerminal(try Self.selectedKey(visible)) == nil, "the other visible pane showed in the focused one's turn")
        launch.frames()
        #expect(cache.existingTerminal(try Self.selectedKey(visible)) != nil, "the other visible pane made no terminal on the next frame")
        #expect(cache.existingTerminal(try Self.selectedKey(keepAlive)) == nil, "the keep-alive pane built before completion")
        #expect(keepAlive.waitsForLaunchEnd)
        #expect(launch.scheduler.startup.completion == nil)
        launch.scheduler.complete()
        #expect(launch.services.launchPanes.viewsBuilt == 2, "views built at completion: \(launch.services.launchPanes.viewsBuilt), not the 2 visible panes")
        launch.frames(10)
        #expect(cache.existingTerminal(try Self.selectedKey(keepAlive)) != nil, "the keep-alive pane made no terminal after completion")
        #expect(launch.services.launchPanes.viewsBuilt == 2, "a view built after completion counted")
    }

    /// A CLI, socket or agent action on a tab the launch holds (a keep-alive pane of the shown workspace) gets its
    /// live content now: the hold is for presentation only, never a refusal ("tab has no live content").
    @Test func anActionOnAHeldPaneMakesItsContentDuringLaunch() throws {
        let launch = try Launch()
        defer { launch.tearDown() }
        let content = try Self.splitWindow(panes: 2, in: launch)
        let focused = try #require(content.focusedPane)
        let pane = try #require(content.panes.values.first { $0 !== focused })
        pane.setPresence(.keepAlive)
        launch.frames()
        let key = try Self.selectedKey(pane)
        #expect(launch.services.cache.existingTerminal(key) == nil, "the keep-alive pane built before completion")
        try #require(pane.waitsForLaunchEnd, "the pane is not held, so this test proves nothing")
        let context = AppActionContext(services: launch.services)
        var entry: TerminalEntry?
        let refusal = launch.services.registry.capturingRefusal {
            entry = context.terminal(ActionInvocation(target: ActionTargetRef(kind: .tab, id: key)))
        }
        #expect(refusal == nil, "an action on a held tab was refused: \(refusal ?? "")")
        #expect(entry != nil && entry === launch.services.cache.existingTerminal(key))
        #expect(launch.scheduler.startup.completion == nil, "the action ran during launch")
    }

    /// A pane the layout has not reported on screen makes no content at launch, and spends no frame's surface creation.
    @Test func aPaneNotOnScreenMakesNoContentAtLaunch() throws {
        let launch = try Launch()
        defer { launch.tearDown() }
        let (state, pane, key) = try Self.pane(in: launch)
        defer { withExtendedLifetime(state) { pane.teardown() } }
        launch.frames()
        #expect(launch.services.pages.existingView(key) == nil, "a pane off screen made its page before startup completed")
        #expect(pane.waitsForLaunchEnd)
        #expect(pane.selectedContentIsAlive, "a held pane counts as cheap to show, so it takes no frame's creation")
        #expect(launch.services.launchPanes.viewsBuilt == 0)
    }

    /// The layout reports the pane on screen: it makes its content before completion, counted as a view built;
    /// not the workspace's focused pane, it waits for the next frame instead of showing in the report's turn.
    @Test func aPaneOnScreenMakesItsContentAndCountsAsBuilt() throws {
        let launch = try Launch()
        defer { launch.tearDown() }
        let (state, pane, key) = try Self.pane(in: launch)
        defer { withExtendedLifetime(state) { pane.teardown() } }
        pane.setPresence(.visible)
        #expect(launch.services.pages.existingView(key) == nil, "a pane that is not the focused one showed in the report's turn")
        launch.frames()
        #expect(launch.services.pages.existingView(key) != nil, "a pane on screen made no content")
        #expect(launch.scheduler.startup.completion == nil)
        #expect(launch.services.launchPanes.viewsBuilt == 1)
    }

    /// A pane in the keep-alive band makes its content right after startup completes, not before.
    @Test func aPaneInTheKeepAliveBandMakesItsContentAfterCompletion() throws {
        let launch = try Launch()
        defer { launch.tearDown() }
        let (state, pane, key) = try Self.pane(in: launch)
        defer { withExtendedLifetime(state) { pane.teardown() } }
        pane.setPresence(.keepAlive)
        launch.frames()
        #expect(launch.services.pages.existingView(key) == nil, "a pane in the keep-alive band built before completion")
        launch.scheduler.complete()
        launch.frames(10)
        #expect(launch.services.pages.existingView(key) != nil, "the keep-alive pane never made its content after completion")
        #expect(!pane.waitsForLaunchEnd)
        #expect(launch.services.launchPanes.viewsBuilt == 0, "a view built after completion counted")
    }

    /// A pane away from the viewport stays model-only after completion, until the layout brings it near.
    @Test func aPaneAwayStaysModelOnlyUntilItComesNear() throws {
        let launch = try Launch()
        defer { launch.tearDown() }
        let (state, pane, key) = try Self.pane(in: launch)
        defer { withExtendedLifetime(state) { pane.teardown() } }
        launch.scheduler.complete()
        launch.frames(10)
        #expect(launch.services.pages.existingView(key) == nil, "a pane away made its content after completion")
        pane.setPresence(.visible)
        launch.frames()
        #expect(launch.services.pages.existingView(key) != nil, "the pane made no content once on screen")
    }
}
